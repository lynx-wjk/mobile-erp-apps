# Phase 7 Safe Analysis: Lifecycle Maintenance

This document provides a technical design for the manual lifecycle maintenance routines. No active background crons are activated; updates are run manually via an RPC with a dry-run feature.

---

## 1. State Transitions & Rules

Subscriptions progress through the following status phases:

```
[ Trialing ] ---> [ Active ] ---> [ Past Due ] ---> [ Suspended ] ---> [ Deleted ]
    |                 |                 |                  |
    +---------> (Expired / Unpaid) -----+------------------+
```

- **Trialing**: Fresh tenant state. Expires in 14 days by default.
- **Active**: Standard paid state.
- **Past Due**: Expiry date exceeded. The system provides a 3-day grace period.
- **Suspended**: Grace period exceeded. Access is blocked; all sync jobs are paused.
- **Deleted**: Tenant is queued for soft-deletion and subsequent token purges.

---

## 2. Maintenance Routine Spec

```sql
CREATE OR REPLACE FUNCTION public.run_subscription_lifecycle_maintenance(
    p_dry_run boolean DEFAULT true
)
RETURNS TABLE (
    tenant_id uuid,
    old_status text,
    new_status text,
    action_taken text
)
SECURITY DEFINER
AS $$
BEGIN
    -- Only Platform Owner can run maintenance manually
    IF NOT public.is_platform_owner() THEN
        RAISE EXCEPTION 'Akses ditolak: Hanya Platform Owner yang dapat menjalankan pemeliharaan.';
    END IF;

    -- A. Transition Trialing/Active to Past Due if expired
    -- B. Transition Past Due to Suspended after 3 days grace
    -- C. Transition Suspended to Deleted if inactive for > 30 days
    
    -- Note: If p_dry_run = true, we log actions to the output TABLE without modifying data.
    -- If p_dry_run = false, we execute UPDATE queries, record events in public.subscription_events,
    -- and return the affected rows.
    
    -- When status transitions to 'suspended' or 'deleted', we stop/cancel all active 
    -- marketplace jobs for the associated tenant_id.
END;
$$ LANGUAGE plpgsql;
```

---

## 3. Testing with Mocked Timestamps

To verify the lifecycle transitions before deployment:
1. Insert a mock tenant with an active subscription expiring in the past:
   ```sql
   INSERT INTO public.tenant_subscriptions (tenant_id, plan_id, status, starts_at, expires_at)
   VALUES ('mock-tenant-uuid', 'plan-uuid', 'active', now() - interval '35 days', now() - interval '5 days');
   ```
2. Run `SELECT * FROM public.run_subscription_lifecycle_maintenance(p_dry_run => true);`. Verify that the tenant is flagged for `past_due` or `suspended` depending on the expiry lag.
3. Assert that when `p_dry_run => false` is executed, the `subscription_events` table logs the state changes.
