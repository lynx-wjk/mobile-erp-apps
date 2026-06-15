# Phase 7A: Subscription Lifecycle Maintenance Audit Result

This document details the audit and implementation notes for the Phase 7A subscription lifecycle maintenance RPC.

---

## 1. Implemented Database RPCs

### A. Lifecycle Maintenance Routine (`run_subscription_lifecycle_maintenance`)
* **Signature**:
  ```sql
  public.run_subscription_lifecycle_maintenance(
    p_dry_run boolean default true,
    p_now timestamptz default now()
  ) returns jsonb
  ```
* **Security**:
  - Defined with `SECURITY DEFINER` and `SET search_path = public` to prevent search path injection attacks.
  - When `p_dry_run = false`, it strictly verifies `public.app_is_platform_owner()` is true.
  - When `p_dry_run = true`, it allows execution only by platform owners or users authenticated with the `service_role` (for future automated background job execution).
* **Return Shape**:
  ```json
  {
    "ok": true,
    "dry_run": true,
    "now": "...",
    "summary": {
      "trial_expired": 0,
      "active_past_due": 0,
      "past_due_suspended": 0,
      "canceled_expired": 0,
      "total_candidates": 0,
      "total_applied": 0
    },
    "candidates": []
  }
  ```

### B. Dry-run Preview Helper (`preview_subscription_lifecycle_maintenance`)
* **Signature**:
  ```sql
  public.preview_subscription_lifecycle_maintenance(
    p_now timestamptz default now()
  ) returns jsonb
  ```
* **Goal**: Convenient read-only helper to run the lifecycle maintenance check without making any changes.

---

## 2. Subscription Lifecycle Transitions

The following state transition rules are coded into the maintenance routine:

1. **`trialing -> expired`**:
   - Matches a subscription where `status = 'trialing'` and `trial_ends_at < p_now`.
2. **`active -> past_due`**:
   - Matches a subscription where `status = 'active'`, `current_period_end < p_now`, and the grace period (`grace_until`) has expired or is unconfigured (`grace_until IS NULL OR grace_until < p_now`).
3. **`past_due -> suspended`**:
   - Matches a subscription where `status = 'past_due'` and `grace_until < p_now`.
4. **`canceled -> expired`**:
   - Matches a subscription where `status = 'canceled'` and `current_period_end < p_now`.

---

## 3. Operations Policy Safeguards
* **No `app_tenants.status` updates**: Confirmed that `app_tenants.status` is never updated or modified by this script, preventing accidental tenant lockouts.
* **No cron automation**: No pg_cron scheduling or triggers are registered.
* **No deletions/purges**: No `DELETE FROM` or `DROP TABLE` operations are executed.
* **Write safety**: Updates `tenant_subscriptions.status`, records the event log in `tenant_subscription_events`, and sets appropriate time audit stamps (`suspended_at` or `canceled_at`) ONLY when `p_dry_run = false`.
