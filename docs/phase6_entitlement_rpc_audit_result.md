# Phase 6A: Subscription Entitlement RPCs Audit Result

This document summarizes the design, audit, and implementation notes for the Phase 6A subscription entitlement database functions.

---

## 1. Helper Functions & Role Verification Security

* **Platform Owner Detection**:
  - Verification is handled by `public.app_is_platform_owner()`.
  - Logic checks `u.role_id = 'platform_owner'` for the authenticated caller `auth.uid()`.
  - This function is defined with `SECURITY DEFINER` and is unversioned.
* **Security Definer Rules**:
  - All new RPCs are defined with `SECURITY DEFINER` and `SET search_path = public` to prevent search path injection attacks.
  - Write commands (`platform_tenant_subscription_set` and `platform_tenant_subscription_override_set`) explicitly check `public.app_is_platform_owner()` and return `{ok: false, error: 'forbidden'}` for unauthorized callers.

---

## 2. Entitlements and Feature Gating Resolution Logic

### A. Feature Entitlement Check (`tenant_has_feature`)
* **Tenant Resolution**:
  - If `p_tenant_id` is passed and the caller is a `platform_owner`, `p_tenant_id` is used.
  - Otherwise, the query automatically resolves to the caller's tenant via `public.app_current_tenant_id_or_default()`.
* **Fallback Rules**:
  - If no active subscription is assigned for the tenant, a safe fallback set of essential features is returned: `stock_basic`, `production_basic`, `finance_basic`, and `invite_management`.
  - The response returns `source: 'fallback'`, `plan_code: 'unassigned'`, and `enabled: true` for fallback features (and `false` for others). This ensures zero breaking behavior for active users.
* **Overrides Resolution Precedence**:
  - Checks plan features mapping (`subscription_plan_features`).
  - Overwrites feature enablement if an active `override_type = 'feature'` row is found in `tenant_subscription_overrides`.

### B. Consolidated Entitlements Check (`get_my_entitlements`)
* Returns the tenant's active subscription state, active plan metadata, and feature key entitlements.
* Overrides for features (`override_type = 'feature'`), limit thresholds (`override_type = 'limit'`), and JSON configurations (`override_type = 'config'`) are merged dynamically into the consolidated dictionary.

---

## 3. Safe Management and Audit Logs

* **`platform_tenant_subscription_set`**:
  - Safely expires any existing active subscriptions by setting their status to `'expired'` to ensure a tenant has at most one active subscription.
  - Inserts the new subscription history record and automatically registers an audit log in `tenant_subscription_events` under the event type `'subscription_updated'`.
* **`platform_tenant_subscription_override_set`**:
  - Inserts manual overrides into `tenant_subscription_overrides`.
  - Automatically registers an audit log in `tenant_subscription_events` under the event type `'override_created'`.
