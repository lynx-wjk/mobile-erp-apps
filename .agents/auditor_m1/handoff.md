# Forensic Audit Report — Milestone 1

**Work Product**: `supabase/migrations/20260815020000_fix_finance_sku_retur_batal_and_unpaid_separation.sql` and live PostgreSQL RPCs (`finance_sku_order_line_details`, `finance_sku_order_details_group_20260625`)  
**Profile**: General Project (Integrity Forensics)  
**Integrity Mode**: Development (from `ORIGINAL_REQUEST.md`)  
**Verdict**: **CLEAN**

---

### Phase Results

- **Check 1: Hardcoded Test Results & Mocks**: **PASS** — No hardcoded counts (e.g. 2435, 1583), order IDs, SKU constants, or fake mock returns found in the migration or database routines.
- **Check 2: Facade Implementations**: **PASS** — Authentic relational joins across `marketplace_orders` (33,678 rows), `marketplace_order_items` (38,072 rows), `marketplace_finance_reports` (29,093 rows), and `marketplace_variant_hpp_mappings` (1,535 rows).
- **Check 3: Fabricated Verification Outputs**: **PASS** — Direct raw SQL queries on underlying database tables independently match the RPC outputs down to the exact single record across all tested time intervals.
- **Check 4: Self-Certifying Tests**: **PASS** — Verification was executed via independent ground-truth SQL scripts completely independent of the stored procedures.
- **Check 5: Live Migration Application**: **PASS** — PostgreSQL function definitions on `inventory-vps` match the migration file verbatim, permissions are granted, and PostgREST schema cache is refreshed.
- **Check 6: Strict Separation of Unpaid vs Returned**: **PASS** — Partitions are strictly mutually exclusive:
  - June 2026: 2,435 returned + 254 unpaid + 13,886 paid = 16,575 total items.
  - July 2026: 1,583 returned + 176 unpaid + 8,386 paid = 10,145 total items.

---

## 1. Observation

### A. Static Code Inspection
Static analysis of `supabase/migrations/20260815020000_fix_finance_sku_retur_batal_and_unpaid_separation.sql` confirms:
1. Dynamic parameter parsing for `p_start`, `p_end`, `p_marketplace`, `p_account_id`, `p_marketplace_sku`, `p_local_sku`, `p_search`, `p_payout_filter`, `p_page`, `p_page_size`.
2. Fully parameterized date boundary logic using Jakarta timezone (`timestamp with time zone`).
3. Clean regex pattern matching for returned/cancelled statuses without hardcoded primary keys.

### B. Live PostgreSQL Table Inventory
Executing table row counts directly on live database (`inventory-vps` / `supabase-db`):
```sql
SELECT 'marketplace_orders' as tbl, count(*) from public.marketplace_orders
UNION ALL SELECT 'marketplace_order_items', count(*) from public.marketplace_order_items
UNION ALL SELECT 'marketplace_finance_reports', count(*) from public.marketplace_finance_reports
UNION ALL SELECT 'marketplace_variant_hpp_mappings', count(*) from public.marketplace_variant_hpp_mappings;
```
**Output**:
```
               tbl                | count 
----------------------------------+-------
 marketplace_variant_hpp_mappings |  1535
 marketplace_orders               | 33678
 marketplace_order_items          | 38072
 marketplace_finance_reports      | 29093
```

### C. Independent Empirical Breakdown vs RPC Results

#### 1. June 2026 (2026-06-01 to 2026-06-30)
- **Raw SQL Table Count**:
  - `total_items`: 16,575
  - `returned_items`: 2,435
  - `unpaid_items`: 254
  - `paid_items`: 13,886
- **RPC `finance_sku_order_line_details`**:
  - `p_payout_filter = 'all'`: `total = 16575`
  - `p_payout_filter = 'returned'`: `total = 2435`
  - `p_payout_filter = 'unpaid'`: `total = 254`
  - `p_payout_filter = 'paid'`: `total = 13886`
- **Result**: 100% exact match across all 4 categories.

#### 2. July 2026 (2026-07-01 to 2026-07-31)
- **Raw SQL Table Count**:
  - `total_items`: 10,145
  - `returned_items`: 1,583
  - `unpaid_items`: 176
  - `paid_items`: 8,386
- **RPC `finance_sku_order_line_details`**:
  - `p_payout_filter = 'all'`: `total = 10145`
  - `p_payout_filter = 'returned'`: `total = 1583`
  - `p_payout_filter = 'unpaid'`: `total = 176`
  - `p_payout_filter = 'paid'`: `total = 8386`
- **Result**: 100% exact match across all 4 categories.

#### 3. Custom Date Window Stress Test (2026-06-15 to 2026-06-20)
- **Raw SQL Count**: `raw_total = 3501`, `raw_returned = 489`
- **RPC Output**: `rpc_total = 3501`, `rpc_returned = 489`
- **Result**: 100% exact match.

---

## 2. Logic Chain

1. **Anti-Cheat Verification**: By comparing the output of the stored procedures with an independently written SQL query that calculates item subsets directly from raw tables, we proved that the stored procedure is computing its output directly from the underlying data with zero fabrication.
2. **Completeness of Requirements**:
   - **R1 (Retur/Batal inclusion)**: Verified that returned/cancelled orders are retained and correctly tagged `is_returned = true` and `payout_status = 'Cancel/Refund/Return'`.
   - **R2 (Strict Pending vs Returned Separation)**: Verified that `qty_unsettled` and `unpaid_hpp` include ONLY active non-cancelled pending orders, and that `qty_returned` and `hpp_return` strictly isolate all return/cancellation costs.
3. **Database Integrity**: The migration is actively deployed to the PostgreSQL instance inside the `supabase-db` container on `inventory-vps` and permissions have been granted to `anon`, `authenticated`, and `service_role`.

---

## 3. Caveats

- **Frontend Scope**: This audit covers the Milestone 1 backend deliverables (database migration and RPC functions). Frontend UI wiring in `finance_report_page.dart` is the subject of Milestone 2.
- **Negative Escrow Payouts**: Orders with negative payouts (platform penalty/shipping return fees) are classified under settled payouts and factored into net margins in accordance with the project's accounting rules.

---

## 4. Conclusion

- **Audit Verdict**: **CLEAN**
- The work product satisfies all forensic integrity checks under Development Mode.
- No shortcuts, mocks, hardcoded constants, or facade logic are present.
- Milestone 1 is verified and approved to proceed to Milestone 2.

---

## 5. Verification Method

To independently reproduce the forensic audit:

1. **Verify Live RPC execution against raw table ground truth for June 2026**:
   ```powershell
   @"
   SELECT
     (public.finance_sku_order_line_details(p_start => '2026-06-01'::date, p_end => '2026-06-30'::date, p_payout_filter => 'all'))->>'total' as total_all,
     (public.finance_sku_order_line_details(p_start => '2026-06-01'::date, p_end => '2026-06-30'::date, p_payout_filter => 'returned'))->>'total' as total_returned,
     (public.finance_sku_order_line_details(p_start => '2026-06-01'::date, p_end => '2026-06-30'::date, p_payout_filter => 'unpaid'))->>'total' as total_unpaid,
     (public.finance_sku_order_line_details(p_start => '2026-06-01'::date, p_end => '2026-06-30'::date, p_payout_filter => 'paid'))->>'total' as total_paid;
   "@ | ssh inventory-vps "docker exec -i supabase-db psql -U postgres -d postgres"
   ```
   *Expected Output*: `16575 | 2435 | 254 | 13886`

2. **Verify live function definition on PostgreSQL**:
   ```powershell
   "SELECT pg_get_functiondef('public.finance_sku_order_line_details(date, date, text, uuid, text, text, text, text, integer, integer)'::regprocedure);" | ssh inventory-vps "docker exec -i supabase-db psql -U postgres -d postgres"
   ```
