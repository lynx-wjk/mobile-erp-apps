# Phase 4 Safe Audit: Marketplace RLS Hardening

This document analyzes Row Level Security (RLS) configuration for all marketplace and operational tracking tables. It proposes policies to lock down access so that tenants can only view/manage their own credentials, syncing logs, and products.

---

## RLS Audit & Proposed Policies

### 1. `marketplace_accounts`
- **Tenant ID Column**: Yes (`tenant_id` UUID)
- **Current Status**: RLS is disabled or has relaxed policies.
- **Read/Write Roles**: Read by `admin` and system worker roles. Write by `admin` (Platform Owner does not manage operational marketplace accounts).
- **Service Role Dependency**: Synchronizer edge functions/workers need read/write access bypassing tenant barriers.
- **Proposed Policy**:
  ```sql
  ALTER TABLE public.marketplace_accounts ENABLE ROW LEVEL SECURITY;

  CREATE POLICY marketplace_accounts_tenant_isolation ON public.marketplace_accounts
    FOR ALL
    TO authenticated
    USING (tenant_id = (SELECT current_setting('app.current_tenant_id', true))::uuid)
    WITH CHECK (tenant_id = (SELECT current_setting('app.current_tenant_id', true))::uuid);
  ```
- **Risk**: Medium. If the edge synchronizer worker does not run as `service_role` (which bypasses RLS), synchronizations will fail.
- **Rollback**:
  ```sql
  ALTER TABLE public.marketplace_accounts DISABLE ROW LEVEL SECURITY;
  DROP POLICY marketplace_accounts_tenant_isolation ON public.marketplace_accounts;
  ```

---

### 2. `marketplace_orders`
- **Tenant ID Column**: Yes (`tenant_id` UUID)
- **Current Status**: RLS disabled.
- **Read/Write Roles**: Read/Write by `admin` and workers.
- **Proposed Policy**:
  ```sql
  ALTER TABLE public.marketplace_orders ENABLE ROW LEVEL SECURITY;

  CREATE POLICY marketplace_orders_tenant_isolation ON public.marketplace_orders
    FOR ALL
    TO authenticated
    USING (tenant_id = (SELECT current_setting('app.current_tenant_id', true))::uuid)
    WITH CHECK (tenant_id = (SELECT current_setting('app.current_tenant_id', true))::uuid);
  ```
- **Risk**: Low. Direct access is protected. Synchronizer runs under `service_role`.

---

### 3. `marketplace_order_pull_jobs`
- **Tenant ID Column**: Yes (`tenant_id` UUID)
- **Current Status**: RLS disabled.
- **Proposed Policy**:
  ```sql
  ALTER TABLE public.marketplace_order_pull_jobs ENABLE ROW LEVEL SECURITY;

  CREATE POLICY marketplace_jobs_tenant_isolation ON public.marketplace_order_pull_jobs
    FOR ALL
    TO authenticated
    USING (tenant_id = (SELECT current_setting('app.current_tenant_id', true))::uuid)
    WITH CHECK (tenant_id = (SELECT current_setting('app.current_tenant_id', true))::uuid);
  ```
- **Risk**: Medium. External job queue processors must execute with `service_role` to fetch pending jobs across all tenants.

---

### 4. `marketplace_sku_maps`
- **Tenant ID Column**: Yes (`tenant_id` UUID)
- **Current Status**: RLS disabled.
- **Proposed Policy**:
  ```sql
  ALTER TABLE public.marketplace_sku_maps ENABLE ROW LEVEL SECURITY;

  CREATE POLICY marketplace_sku_maps_tenant_isolation ON public.marketplace_sku_maps
    FOR ALL
    TO authenticated
    USING (tenant_id = (SELECT current_setting('app.current_tenant_id', true))::uuid)
    WITH CHECK (tenant_id = (SELECT current_setting('app.current_tenant_id', true))::uuid);
  ```
- **Risk**: Low. Safe mapping screen isolation.

---

## Safe Migration Strategy

1. **Step 1**: Do NOT enable RLS until all edge functions and queue workers are confirmed to connect using the `service_role` client API.
2. **Step 2**: Write a secure configuration function to inject `app.current_tenant_id` dynamically in RPCs.
3. **Step 3**: Deploy policies in a separate migration script. Do not bundle RLS changes with functional updates.
