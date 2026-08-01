# Tenant Isolation Dry-Run Report

This report summarizes the findings of the logical tenant isolation audit and data split dry-run validation conducted on the self-hosted Supabase database.

---

## 1. Database Overview

* **Database Version**: PostgreSQL 15.8
* **Public Tables**: 104 total tables in the `public` schema.
  - **Tenant-Scoped Tables**: 91 tables containing the `tenant_id` column.
  - **Global Tables**: 13 tables without `tenant_id`. These consist of:
    - Global Configurations: `feature_catalog`, `roles`, `subscription_plans`, `subscription_plan_features`.
    - Local caches: `finance_dashboard_snapshot_cache_v24_6_73`, `finance_report_cache_events_v24_6_82`, `finance_report_period_snapshot_cache_v24_6_82`, `finance_report_sku_detail_cache_60d_v24_6_82`.
    - Log & Lock Tables: `marketplace_auto_pull_request_log_v24_6_82q`, `marketplace_auto_runner_locks`, `marketplace_cron_edge_config_v24_6_82q`, `marketplace_export_import_rows`, `marketplace_finance_export_import_rows`.

---

## 2. Row Counts per Tenant

The row count tallies reveal that a single tenant holds 99.9%+ of all records:

* **Tenant `hai_internal`** (`ae730499-550b-4907-bb18-bbc2629c64f4`):
  - `marketplace_orders`: 43,714 rows
  - `marketplace_order_items`: 74,436 rows
  - `marketplace_finance_reports`: 37,773 rows
  - `marketplace_variant_hpp_mappings`: 1,493 rows
* **Tenant `reviewer_demo`** (`93f3372f-59dd-4e7c-ba4f-c146f622611c`):
  - 0 rows across main marketplace tables.
* **Tenant `noir_nattire_studio_89f4`** (`7c57aa17-4503-4b4c-86e6-5cb4c01b9be0`):
  - 0 rows across main marketplace tables.

---

## 3. Data Integrity & Leakage Verification

Our dry-run split validation script successfully verified the following parameters:

* **Null Tenant ID Audit**:
  - **0 rows** with NULL `tenant_id` were found in any tenant-scoped tables.
* **Cross-Tenant Leakage Check**:
  - **0 order item tenant mismatches** (all items share the exact tenant ID of their parent order).
  - **0 finance report tenant mismatches** (all finance reports match the tenant ID of their referenced orders).
  - **0 invalid tenant accounts** (all accounts reference a valid registered tenant in `public.app_tenants`).
* **Global Configuration Accessibility**:
  - Verified global catalog contains 21 features, 15 roles, 6 subscription plans, and 126 plan features. All are globally shared and intact.

---

## 4. Routine & pg_cron Analysis

* **RPC Functions**:
  - Functions like `finance_sku_order_details` and `finance_marketplace_profit_loss_detail` rely on user claims to fetch the caller's `tenant_id` automatically from the request JWT.
  - This design is highly robust as it prevents the user from manually passing or manipulating a different `tenant_id` in their HTTP queries.
* **pg_cron Jobs**:
  - Current cron jobs (e.g. historical data sync and auto-reconciliation dispatchers) are scheduled globally. They process accounts sequentially, reading the associated `tenant_id` directly from `public.marketplace_accounts` to isolate execution loops.

---

## 5. Summary Recommendation

Given that the database is completely clean, with zero orphan rows and zero cross-tenant references, the data is perfectly prepared for logical partition isolation. 

We recommend maintaining **Option A** (Shared DB with strict RLS) and scaling using **Postgres Declarative Partitioning by Tenant** for large-scale tables, rather than splitting into separate databases or schemas which would introduce unnecessary maintenance and migration risks.
