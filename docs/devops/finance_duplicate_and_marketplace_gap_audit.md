# Finance Duplicate and Marketplace Gap Audit Report
**Path**: `docs/devops/finance_duplicate_and_marketplace_gap_audit.md`

## 1. Overview of Duplicate Entries in Finance Reports
Duplicate entries in the `marketplace_finance_reports` and `marketplace_order_items` tables can result in double-counting of payouts, HPP, and marketplace fees, which skews profit/loss calculations. 

Duplicates typically arise from:
- Concurrent backfill jobs or manual sync triggers running in parallel.
- Overlapping webhook event deliveries without idempotent insertion guards.
- Mismatches in order SN formats (e.g., trailing spaces or prefix differences) when joining between order tables and raw report imports.

---

## 2. Key Audit Fields & Patterns
The read-only audit script at [audit_finance_duplicates_readonly.sql](file:///C:/Users/budic/Downloads/android/inventory_control_apps/supabase/sql/audit_finance_duplicates_readonly.sql) tracks duplicates across the following fields:
- `marketplace` & `marketplace_account_id`
- `order_sn` / `order_id` (marketplace order sequence numbers)
- `statement_id` (settlement identifier from the marketplace)
- `payout_amount` / `received_amount`
- `marketplace_order_item_id` (for line-level item duplication)

---

## 3. Marketplace Settlement Gap Examples
Settlement gaps refer to orders that have been completed and delivered but either:
1. Have no payout recorded in `marketplace_finance_reports`.
2. Have a payout recorded under an unrecognized order SN (orphaned payouts).
3. Have a mismatch between client-side computed payout and actual net settlement.

Common reasons for gap occurrences:
- **Shopee Escrow Delay**: Payout is pending escrow release, which can take up to 7-14 days.
- **TikTok Shop Deduction**: Affiliate fees or platform vouchers deducted directly from settlement without explicit itemized lines.

---

## 4. Duplicate Cleanup & Safe Rollback Plan (Dry Run)
If duplicates are proven by running the query in Section 1 of the SQL script, a separate cleanup should be performed. 

### SELECT Preview Query
Before executing any deletion, preview the rows that will be removed:
```sql
with duplicate_ranks as (
  select
    finance_report_id,
    row_number() over (
      partition by tenant_id, marketplace, marketplace_account_id, order_id, statement_id
      order by created_at asc, finance_report_id asc
    ) as row_rank
  from public.marketplace_finance_reports
)
select * from public.marketplace_finance_reports
where finance_report_id in (
  select finance_report_id from duplicate_ranks where row_rank > 1
);
```

### Deletion Script (DO NOT RUN YET)
```sql
begin;

-- Save backup first
create temp table backup_marketplace_finance_reports as 
with duplicate_ranks as (
  select
    finance_report_id,
    row_number() over (
      partition by tenant_id, marketplace, marketplace_account_id, order_id, statement_id
      order by created_at asc, finance_report_id asc
    ) as row_rank
  from public.marketplace_finance_reports
)
select * from public.marketplace_finance_reports
where finance_report_id in (
  select finance_report_id from duplicate_ranks where row_rank > 1
);

-- Execute DELETE only for ranked duplicates
delete from public.marketplace_finance_reports
where finance_report_id in (
  select finance_report_id from backup_marketplace_finance_reports
);

commit;
```

### Rollback Plan
If the cleanup causes data discrepancies, restore the deleted records from the temporary backup table before the transaction or session ends:
```sql
insert into public.marketplace_finance_reports
select * from backup_marketplace_finance_reports;
```
