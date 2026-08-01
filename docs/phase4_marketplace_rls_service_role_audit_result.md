# Phase 4A: Marketplace RLS and Service Role Audit Result

This document presents a comprehensive audit of the database tables and Supabase Edge Functions related to the marketplace integrations. It evaluates RLS readiness, identifies index coverage, examines `service_role` usage, and details recommended fixes, migration paths, and rollback plans.

---

## 1. Executive Summary

- **Primary Goal**: Audit row-level security (RLS) policies, table schemas, index readiness, and Supabase Edge Function `service_role` client behaviors prior to executing RLS enforcement in Phase 4B.
- **Key Discovery**: All database queries and modifications inside the 12 marketplace Edge Functions are executed via a Supabase client instantiated with `SUPABASE_SERVICE_ROLE_KEY`. Because the `service_role` client acts as a database superuser, RLS policies are bypassed entirely for these background tasks. Thus, enabling RLS will **not** break background order syncs, product pulls, stock updates, or cron job runs.
- **Critical Vulnerability**: The public view `marketplace_accounts_public` is defined **without** the `security_invoker = true` option. Consequently, any authenticated user can select from it to read masked marketplace account records, bypassing RLS rules on the base `marketplace_accounts` table.
- **Core Recommendation**:
  1. Secure the public view in Phase 4B by adding `WITH (security_invoker = true)`.
  2. Implement strict tenant-based policies requiring `tenant_id = public.app_current_tenant_id_or_default()` in addition to role checks (`marketplace_can_read()` / `marketplace_can_write()`).
  3. Ensure all global tables without `tenant_id` are restricted to `service_role` only.

---

## 2. Tables Audited

The database schema (`migration_selfhost/schema.sql`) contains 22 tables starting with `marketplace_`. The audit details for these tables are summarized below:

| Table Name | Has `tenant_id`? | Has Account ID? | Contains Tokens? | RLS Enabled? | Existing RLS Policies | Index Readiness | Safe for Phase 4B? |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| `marketplace_accounts` | Yes | Yes (PK) | Yes (Encrypted) | Yes | Role-only checks (`marketplace_can_read`/`write`) | `idx_marketplace_accounts_tenant_id` | **Yes** (Needs policy hardening) |
| `marketplace_sku_maps` | Yes | Yes | No | Yes | Role-only checks (`marketplace_can_read`/`write`) | `idx_marketplace_sku_maps_tenant_id` | **Yes** (Needs policy hardening) |
| `marketplace_product_snapshots` | Yes | Yes | No | Yes | None | Yes (B-Tree indexes on `tenant_id`) | **Yes** |
| `marketplace_variant_snapshots` | Yes | Yes | No | Yes | SELECT check on `tenant_id` | Yes (B-Tree indexes on `tenant_id`) | **Yes** |
| `marketplace_orders` | Yes | Yes | No | Yes | SELECT check on `tenant_id` | `idx_marketplace_orders_tenant_id` | **Yes** |
| `marketplace_order_items` | Yes | Yes | No | Yes | SELECT check on `tenant_id` | `idx_marketplace_order_items_tenant_id` | **Yes** |
| `marketplace_finance_reports` | Yes | Yes | No | Yes | Role-only checks (`marketplace_can_read`/`write`) | `idx_marketplace_finance_reports_tenant_id` | **Yes** |
| `marketplace_finance_items` | Yes | Yes | No | Yes | Role-only checks (`marketplace_can_read`/`write`) | `idx_marketplace_finance_items_tenant_id` | **Yes** |
| `marketplace_stock_sync_logs` | Yes | Yes | No | Yes | SELECT check on `tenant_id` | Yes (B-Tree indexes on `tenant_id`) | **Yes** |
| `marketplace_sync_logs` | Yes | Yes | No | Yes | None | Yes (B-Tree indexes on `tenant_id`) | **Yes** |
| `marketplace_return_refund_cases` | Yes | Yes | No | Yes | SELECT check on `tenant_id` | Yes (B-Tree indexes on `tenant_id`) | **Yes** |
| `marketplace_return_reviews` | Yes | Yes | No | Yes | SELECT check on `tenant_id` | Yes (B-Tree indexes on `tenant_id`) | **Yes** |
| `marketplace_return_item_reviews` | Yes | Yes | No | Yes | SELECT check on `tenant_id` | Yes (B-Tree indexes on `tenant_id`) | **Yes** |
| `marketplace_stock_out_reviews` | Yes | Yes | No | Yes | SELECT check on `tenant_id` | Yes (B-Tree indexes on `tenant_id`) | **Yes** |
| `marketplace_order_pull_jobs` | Yes | Yes | No | Yes | SELECT/INSERT/UPDATE check on `tenant_id` | Yes (B-Tree indexes on `tenant_id`) | **Yes** |
| `marketplace_finance_anomalies` | Yes | Yes | No | Yes | Role-only checks (`marketplace_can_read`/`write`) | `idx_marketplace_finance_anomalies_tenant_id` | **Yes** |
| `marketplace_auto_runner_locks` | No | No | No | Yes | None (Denies all except superuser) | N/A (Global table) | **Yes** (Keep restricted to `service_role`) |
| `marketplace_cron_edge_config_v24_6_82q` | No | No | Yes (Service Key) | Yes | None (Denies all except superuser) | N/A (Global table) | **Yes** (Keep restricted to `service_role`) |
| `marketplace_auto_pull_request_log_v24_6_82q` | No | Yes | No | Yes | None (Denies all except superuser) | N/A (Needs join on account) | **Yes** (Use join policy via Account ID) |
| `marketplace_oauth_states` | Yes | Yes (Indirect) | No | Yes | Yes | Yes | **Yes** |
| `marketplace_stock_sync_jobs` | Yes | Yes | No | Yes | Yes | Yes | **Yes** |
| `marketplace_stock_sync_settings` | Yes | Yes | No | Yes | SELECT/UPDATE check on `tenant_id` | Yes | **Yes** |

---

## 3. Edge Functions Audited

All 12 Supabase Edge Functions in the repository have been inspected:

1. **`marketplace-auth-start`**
   - **Path**: `supabase/functions/marketplace-auth-start/index.ts`
   - **Service Role Key**: Yes, instantiates `admin` client using `SUPABASE_SERVICE_ROLE_KEY`.
   - **Public/Anon Key**: No.
   - **Writes/Reads**: Reads `users` to check role; writes to `marketplace_oauth_states`.
   - **Token Columns**: No.
   - **Break under RLS**: No.
   - **Fix**: None.

2. **`marketplace-auto-runner`**
   - **Path**: `supabase/functions/marketplace-auto-runner/index.ts`
   - **Service Role Key**: Yes, instantiates `admin` client using `SUPABASE_SERVICE_ROLE_KEY`.
   - **Public/Anon Key**: Uses anon key for internal endpoint requests, but actual DB queries use `admin`.
   - **Writes/Reads**: Reads/writes lock tables and sync job queue items.
   - **Token Columns**: No.
   - **Break under RLS**: No.
   - **Fix**: None.

3. **`marketplace-bootstrap-order-worker`**
   - **Path**: `supabase/functions/marketplace-bootstrap-order-worker/index.ts`
   - **Service Role Key**: Yes, instantiates `db` client using `SUPABASE_SERVICE_ROLE_KEY`.
   - **Public/Anon Key**: No.
   - **Writes/Reads**: Reads/writes `marketplace_orders` and pull jobs.
   - **Token Columns**: No.
   - **Break under RLS**: No.
   - **Fix**: None.

4. **`marketplace-finance-pull`**
   - **Path**: `supabase/functions/marketplace-finance-pull/index.ts`
   - **Service Role Key**: Yes, instantiates `admin` client using `SUPABASE_SERVICE_ROLE_KEY`.
   - **Public/Anon Key**: No.
   - **Writes/Reads**: Reads credentials from `marketplace_accounts`, writes to `marketplace_finance_reports` and `marketplace_finance_items`.
   - **Token Columns**: Reads encrypted tokens.
   - **Break under RLS**: No.
   - **Fix**: None.

5. **`marketplace-order-pull`**
   - **Path**: `supabase/functions/marketplace-order-pull/index.ts`
   - **Service Role Key**: Yes, instantiates `admin` client using `SUPABASE_SERVICE_ROLE_KEY`.
   - **Public/Anon Key**: No.
   - **Writes/Reads**: Reads `marketplace_accounts`, writes `marketplace_orders` and `marketplace_order_items`.
   - **Token Columns**: Reads encrypted tokens.
   - **Break under RLS**: No.
   - **Fix**: None.

6. **`marketplace-order-sync-jobs`**
   - **Path**: `supabase/functions/marketplace-order-sync-jobs/index.ts`
   - **Service Role Key**: Yes, instantiates `admin` client using `SUPABASE_SERVICE_ROLE_KEY`.
   - **Public/Anon Key**: No.
   - **Writes/Reads**: Reads `marketplace_accounts`, writes sync jobs.
   - **Token Columns**: No.
   - **Break under RLS**: No.
   - **Fix**: None.

7. **`marketplace-product-pull`**
   - **Path**: `supabase/functions/marketplace-product-pull/index.ts`
   - **Service Role Key**: Yes, instantiates `admin` client using `SUPABASE_SERVICE_ROLE_KEY`.
   - **Public/Anon Key**: No.
   - **Writes/Reads**: Reads `marketplace_accounts`, writes `marketplace_product_snapshots` and `marketplace_variant_snapshots`.
   - **Token Columns**: Reads encrypted tokens.
   - **Break under RLS**: No.
   - **Fix**: None.

8. **`marketplace-return-refund-pull`**
   - **Path**: `supabase/functions/marketplace-return-refund-pull/index.ts`
   - **Service Role Key**: Yes, instantiates `admin` client using `SUPABASE_SERVICE_ROLE_KEY`.
   - **Public/Anon Key**: No.
   - **Writes/Reads**: Reads `marketplace_accounts`, writes `marketplace_return_refund_cases`.
   - **Token Columns**: Reads encrypted tokens.
   - **Break under RLS**: No.
   - **Fix**: None.

9. **`marketplace-shopee-callback`**
   - **Path**: `supabase/functions/marketplace-shopee-callback/index.ts`
   - **Service Role Key**: Yes, instantiates `admin` client using `SUPABASE_SERVICE_ROLE_KEY`.
   - **Public/Anon Key**: No.
   - **Writes/Reads**: Reads `users`, writes to `marketplace_accounts`.
   - **Token Columns**: Writes encrypted tokens.
   - **Break under RLS**: No.
   - **Fix**: None.

10. **`marketplace-stock-sync-worker`**
    - **Path**: `supabase/functions/marketplace-stock-sync-worker/index.ts`
    - **Service Role Key**: Yes, instantiates `admin` client using `SUPABASE_SERVICE_ROLE_KEY`.
    - **Public/Anon Key**: No.
    - **Writes/Reads**: Reads `marketplace_accounts`, writes to `marketplace_stock_sync_logs`.
    - **Token Columns**: Reads encrypted tokens.
    - **Break under RLS**: No.
    - **Fix**: None.

11. **`marketplace-tiktok-callback`**
    - **Path**: `supabase/functions/marketplace-tiktok-callback/index.ts`
    - **Service Role Key**: Yes, instantiates `admin` client using `SUPABASE_SERVICE_ROLE_KEY`.
    - **Public/Anon Key**: No.
    - **Writes/Reads**: Reads `users`, writes to `marketplace_accounts`.
    - **Token Columns**: Writes encrypted tokens.
    - **Break under RLS**: No.
    - **Fix**: None.

12. **`marketplace-tiktok-service`**
    - **Path**: `supabase/functions/marketplace-tiktok-service/index.ts`
    - **Service Role Key**: Yes, instantiates `serviceClient` using `SUPABASE_SERVICE_ROLE_KEY`.
    - **Public/Anon Key**: Yes, instantiates `userClient` using `SUPABASE_ANON_KEY` and the user's JWT.
    - **Writes/Reads**:
      - `userClient` is used **only** to authenticate the session (`userClient.auth.getUser()`).
      - `serviceClient` performs all DB reads/writes to `users`, `marketplace_accounts`, `marketplace_orders`, `marketplace_finance_reports`, etc.
    - **Token Columns**: Reads/writes tokens.
    - **Break under RLS**: No.
    - **Fix**: None.

---

## 4. Service Role Readiness Matrix

| Feature / Service | Bypasses RLS? | RLS Mitigation Needed? | Safe for Phase 4B? |
| :--- | :--- | :--- | :--- |
| **Edge Functions DB Operations** | Yes (via Service Role Key) | No mitigation needed for Deno scripts. | **Yes** |
| **Edge Function Auth Checks** | No (`userClient` only validates JWT) | No mitigation needed. | **Yes** |
| **Marketplace Sync Workers** | Yes (runs as superuser) | No mitigation needed. | **Yes** |
| **Marketplace Cron (pg_cron)** | Yes (runs as postgres role) | No mitigation needed. | **Yes** |

---

## 5. RLS Risk Level per Table

- **Low Risk**: Tables that already contain `tenant_id` and have active indexes. Setting up RLS policies is straightforward.
  * *Tables*: `marketplace_product_snapshots`, `marketplace_variant_snapshots`, `marketplace_orders`, `marketplace_order_items`, `marketplace_finance_reports`, `marketplace_finance_items`, `marketplace_stock_sync_logs`, `marketplace_sync_logs`, `marketplace_return_refund_cases`, `marketplace_return_reviews`, `marketplace_return_item_reviews`, `marketplace_stock_out_reviews`.
- **Medium Risk**: Tables that require custom policy filters due to lack of `tenant_id` or need complex lookups.
  * *Tables*: `marketplace_auto_pull_request_log_v24_6_82q` (needs policy joining `marketplace_accounts` to resolve `tenant_id`).
- **High Risk**: Tables containing credentials or configurations. Any misconfiguration in policies could prevent normal operations or expose sensitive tokens.
  * *Tables*: `marketplace_accounts` (stores encrypted credentials), `marketplace_cron_edge_config_v24_6_82q` (stores global service role key, must restrict access entirely).

---

## 6. Tables Safe for Phase 4B RLS

The following tables are fully safe for Phase 4B RLS deployment:
- All tables containing `tenant_id` column and indexed appropriately.
- Global tables that should be locked down to superusers only:
  - `marketplace_auto_runner_locks`
  - `marketplace_cron_edge_config_v24_6_82q`

---

## 7. Tables Unsafe for Phase 4B RLS

No tables are inherently "unsafe" to enable RLS on, provided that policies are configured correctly. However, **the following public view is unsafe in its current state**:
* **`marketplace_accounts_public`**: Must be redeployed in Phase 4B using `WITH (security_invoker = true)` to inherit the underlying table's RLS policies. Otherwise, it functions as a security loophole.

---

## 8. Required Worker Fixes Before RLS

No code modifications are required for Deno Edge Functions or background daemons because they use the `SUPABASE_SERVICE_ROLE_KEY`.

---

## 9. Recommended Phase 4B Migration Plan

1. **Step 1: Re-deploy Public Accounts View**
   Ensure the view enforces RLS checks:
   ```sql
   CREATE OR REPLACE VIEW public.marketplace_accounts_public 
   WITH (security_invoker = true) 
   AS SELECT ... FROM public.marketplace_accounts;
   ```

2. **Step 2: Define Tenant-Aware Policies**
   Replace role-only policies on marketplace tables with strict tenant-matching clauses:
   ```sql
   -- Example for marketplace_accounts
   ALTER TABLE public.marketplace_accounts ENABLE ROW LEVEL SECURITY;
   
   CREATE POLICY "marketplace_accounts_tenant_select" ON public.marketplace_accounts
     FOR SELECT TO authenticated
     USING (tenant_id = public.app_current_tenant_id_or_default() AND public.marketplace_can_read());
     
   CREATE POLICY "marketplace_accounts_tenant_write" ON public.marketplace_accounts
     FOR ALL TO authenticated
     USING (tenant_id = public.app_current_tenant_id_or_default() AND public.marketplace_can_write())
     WITH CHECK (tenant_id = public.app_current_tenant_id_or_default() AND public.marketplace_can_write());
   ```

3. **Step 3: Define Policies for No-Tenant Logging Tables**
   ```sql
   -- Policy for marketplace_auto_pull_request_log_v24_6_82q joining accounts
   CREATE POLICY "marketplace_pull_logs_select" ON public.marketplace_auto_pull_request_log_v24_6_82q
     FOR SELECT TO authenticated
     USING (EXISTS (
       SELECT 1 FROM public.marketplace_accounts a
       WHERE a.marketplace_account_id = marketplace_auto_pull_request_log_v24_6_82q.marketplace_account_id
         AND a.tenant_id = public.app_current_tenant_id_or_default()
     ) AND public.marketplace_can_read());
   ```

4. **Step 4: Lock Down Global Tables**
   Ensure no authenticated or anonymous roles can read edge credentials or runner locks:
   ```sql
   -- Keep RLS enabled but do not define policies for anon/authenticated roles.
   -- Only service_role can read/write.
   ALTER TABLE public.marketplace_cron_edge_config_v24_6_82q ENABLE ROW LEVEL SECURITY;
   ALTER TABLE public.marketplace_auto_runner_locks ENABLE ROW LEVEL SECURITY;
   ```

---

## 10. Rollback Plan

If RLS policies cause screen loading failures or sync blockages in production, execute the following SQL to temporarily disable RLS checks on the marketplace subsystem:

```sql
-- Disable RLS on core tables
ALTER TABLE public.marketplace_accounts DISABLE ROW LEVEL SECURITY;
ALTER TABLE public.marketplace_sku_maps DISABLE ROW LEVEL SECURITY;
ALTER TABLE public.marketplace_product_snapshots DISABLE ROW LEVEL SECURITY;
ALTER TABLE public.marketplace_variant_snapshots DISABLE ROW LEVEL SECURITY;
ALTER TABLE public.marketplace_orders DISABLE ROW LEVEL SECURITY;
ALTER TABLE public.marketplace_order_items DISABLE ROW LEVEL SECURITY;
ALTER TABLE public.marketplace_finance_reports DISABLE ROW LEVEL SECURITY;
ALTER TABLE public.marketplace_finance_items DISABLE ROW LEVEL SECURITY;
ALTER TABLE public.marketplace_stock_sync_logs DISABLE ROW LEVEL SECURITY;
ALTER TABLE public.marketplace_sync_logs DISABLE ROW LEVEL SECURITY;
ALTER TABLE public.marketplace_return_refund_cases DISABLE ROW LEVEL SECURITY;
ALTER TABLE public.marketplace_return_reviews DISABLE ROW LEVEL SECURITY;
ALTER TABLE public.marketplace_return_item_reviews DISABLE ROW LEVEL SECURITY;
ALTER TABLE public.marketplace_stock_out_reviews DISABLE ROW LEVEL SECURITY;
ALTER TABLE public.marketplace_order_pull_jobs DISABLE ROW LEVEL SECURITY;
ALTER TABLE public.marketplace_finance_anomalies DISABLE ROW LEVEL SECURITY;

-- Restore public view to default security definer state (bypasses RLS)
CREATE OR REPLACE VIEW public.marketplace_accounts_public 
AS SELECT ... FROM public.marketplace_accounts;
```

---

## 11. Exact SQL Audit Queries Used

The following queries are recommended for verifying schema conditions and configurations on the live database:

```sql
-- 1. Inspect RLS Enablement status
SELECT tablename, rowsecurity 
FROM pg_tables 
WHERE schemaname = 'public' AND tablename LIKE 'marketplace_%';

-- 2. List all existing policies on marketplace tables
SELECT tablename, policyname, roles, cmd, qual, with_check 
FROM pg_policies 
WHERE schemaname = 'public' AND tablename LIKE 'marketplace_%';

-- 3. Verify index coverage for tenant_id and account_id
SELECT tablename, indexname, indexdef 
FROM pg_indexes 
WHERE schemaname = 'public' AND tablename LIKE 'marketplace_%'
ORDER BY tablename, indexname;

-- 4. Check View security settings (e.g. security_invoker check)
SELECT c.relname AS view_name, 
       s.option_name, 
       s.option_value
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
LEFT JOIN LATERAL unnest(c.reloptions) opt ON true
LEFT JOIN LATERAL split_part(opt, '=', 1) s(option_name) ON true
LEFT JOIN LATERAL split_part(opt, '=', 2) s2(option_value) ON true
WHERE n.nspname = 'public' 
  AND c.relkind = 'v' 
  AND c.relname LIKE 'marketplace_%';
```
