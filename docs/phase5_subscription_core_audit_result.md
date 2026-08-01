# Phase 5A: SaaS Subscription Core Schema Audit

This document summarizes the findings from the schema audit of the database before creating the new SaaS subscription core schema.

---

## 1. Schema Audit Findings

### A. Tenant Table (`app_tenants`)
* **Key Columns**:
  - `tenant_id` (UUID, primary key)
  - `tenant_code` (text, unique name identifier)
  - `tenant_name` (text, display name)
  - `owner_name` / `owner_email` (owner contact details)
  - `status` (text, defaults to `'active'`)
* **Check Constraints**:
  - `status` must be `'active'`, `'inactive'`, or `'suspended'`.
* **Implications**: The new `tenant_subscriptions` table should have a foreign key references `public.app_tenants(tenant_id)`. During future lifecycle maintenance, tenant status transitions must coordinate with subscription states.

### B. User Table (`users`) and Roles
* **Key Columns**:
  - `user_id` (UUID, primary key)
  - `email` (text)
  - `role_id` (text, foreign key references `roles.role_id`)
  - `tenant_id` (UUID, foreign key references `app_tenants.tenant_id`)
* **Platform Owner Definition**:
  - The `'platform_owner'` role was added to `public.roles` in Phase 1.
  - Access bypass functions (e.g. `app_has_tenant_access(p_tenant_id)`) exist, checking `u.role_id = 'platform_owner'`.
  - We can define a clean database helper function `public.app_is_platform_owner()` in the new migration to verify the active platform owner's authentication context cleanly.

### C. Existing Subscription or Billing Tables
* No subscription, pricing plan, invoice, or package billing structures exist in `schema.sql` or subsequent migrations. This provides a completely clean slate for deploying the new SaaS subscription schema.

### D. Marketplace Account Limits Reference
* **Key Column**: `marketplace_accounts.marketplace` checks check constraints to restrict to `'shopee'` or `'tiktok_shop'`.
* **Implications**: Plans can define custom limits on marketplace connections (e.g. `max_shopee_accounts`, `max_tiktok_accounts`, and `max_marketplace_accounts`) which sync processes can inspect in future phases.

---

## 2. Seeding Strategy

* **`feature_catalog`**: Seeded with 21 keys across admin, stock, production, finance, marketplace, hr, and general groups.
* **`subscription_plans`**: Seeded with 5 core plan tiers (`trial`, `starter`, `growth`, `pro`, `enterprise`).
* **`subscription_plan_features`**: Sets default feature mappings per plan.

---

## 3. RLS and Security Strategy

* All master tables (`feature_catalog`, `subscription_plans`, `subscription_plan_features`) allow `SELECT` for all authenticated users but restrict modifications (`INSERT/UPDATE/DELETE`) to platform owners.
* Tenant-specific tables (`tenant_subscriptions`, `tenant_subscription_overrides`, `tenant_subscription_events`) allow `SELECT` for authenticated users belonging to that tenant or platform owners, while write commands are restricted solely to platform owners (or superuser service roles).
* The audit logging table `tenant_deletion_audit` is completely restricted to platform owners.

---

## 4. No-Enforcement / Safe Fallback Policy
* No constraints or middleware checks are active yet to block access.
* Staged optional helper RPCs return a default `'unassigned'` payload with a safe fallback of essential features (`stock_basic`, `production_basic`, `finance_basic`, `invite_management`) for any tenant lacking an explicit subscription record. This guarantees zero breaking behavior for existing users.
