# Phase 6 Safe Analysis: Entitlement RPCs

This document defines the interface and implementation requirements for subscription management and entitlement checking RPCs.

---

## 1. RPC Signatures & Specifications

### `platform_subscription_plan_list()`
- **Access**: Platform Owner Only.
- **Returns**: `SETOF jsonb` (lists all subscription plans and their feature catalogs).
- **Signature**:
  ```sql
  CREATE OR REPLACE FUNCTION public.platform_subscription_plan_list()
  RETURNS SETOF jsonb
  SECURITY DEFINER
  AS $$
  BEGIN
      -- Verify current user is platform_owner
      IF NOT public.is_platform_owner() THEN
          RAISE EXCEPTION 'Akses ditolak: Hanya Platform Owner yang dapat mengakses data ini.';
      END IF;

      RETURN QUERY
      SELECT jsonb_build_object(
          'plan_id', p.plan_id,
          'code', p.code,
          'name', p.name,
          'price', p.price,
          'is_active', p.is_active,
          'features', coalesce(
              (SELECT jsonb_agg(jsonb_build_object('feature_id', pf.feature_id, 'is_enabled', pf.is_enabled))
               FROM public.subscription_plan_features pf WHERE pf.plan_id = p.plan_id),
              '[]'::jsonb
          )
      ) FROM public.subscription_plans p;
  END;
  $$ LANGUAGE plpgsql;
  ```

### `platform_tenant_subscription_set(p_tenant_id uuid, p_plan_id uuid, p_duration_days int)`
- **Access**: Platform Owner Only.
- **Returns**: `jsonb` (status and details of the new subscription).
- **Behavior**: Ends previous active subscriptions and creates a new one starting now.

### `tenant_has_feature(p_feature_id text)`
- **Access**: Authenticated users within the tenant.
- **Returns**: `boolean`
- **Logic**:
  ```sql
  CREATE OR REPLACE FUNCTION public.tenant_has_feature(p_feature_id text)
  RETURNS boolean
  SECURITY DEFINER
  AS $$
  DECLARE
      v_tenant_id uuid;
      v_override_enabled boolean;
      v_plan_enabled boolean;
      v_status text;
  BEGIN
      -- Retrieve current tenant context
      v_tenant_id := (SELECT current_setting('app.current_tenant_id', true))::uuid;
      IF v_tenant_id IS NULL THEN
          RETURN false;
      END IF;

      -- Check 1: Tenant-level override
      SELECT is_enabled INTO v_override_enabled
      FROM public.tenant_feature_overrides
      WHERE tenant_id = v_tenant_id AND feature_id = p_feature_id;

      IF v_override_enabled IS NOT NULL THEN
          RETURN v_override_enabled;
      END IF;

      -- Check 2: Active subscription status
      SELECT ts.status, pf.is_enabled INTO v_status, v_plan_enabled
      FROM public.tenant_subscriptions ts
      JOIN public.subscription_plan_features pf ON pf.plan_id = ts.plan_id
      WHERE ts.tenant_id = v_tenant_id
        AND ts.status IN ('trialing', 'active')
        AND ts.expires_at > now()
        AND pf.feature_id = p_feature_id
      LIMIT 1;

      RETURN COALESCE(v_plan_enabled, false);
  END;
  $$ LANGUAGE plpgsql;
  ```

### `get_my_entitlements()`
- **Access**: Any authenticated user.
- **Returns**: `jsonb` (Key-value map of feature flags: `{"marketplace_sync": true, "finance_reports": false}`)
- **Behavior**: Evaluates all catalog features against `tenant_has_feature()` for the caller's tenant.

---

## 2. Failure Modes & Edge Cases

1. **Orphaned Tenants**: If a tenant has no active subscription rows, `tenant_has_feature` must default to `false`.
2. **Expired Subscription**: If a subscription's `expires_at` is in the past, `tenant_has_feature` must instantly deny access.
3. **Impersonation Prevention**: Both RPC checks and policies must strictly enforce `is_platform_owner()` checks before modifying subscription properties.
