# Phase 9 Safe Analysis: Scalable Autojob Queue

This document specifies the architecture for a highly concurrent and scalable auto-sync job queue, ensuring fair resource sharing, tenant subscription checks, and lease management.

---

## 1. Schema Design

### `platform_job_queue`
Stores individual work items (e.g. sync tiktok shop orders for a specific window).
```sql
CREATE TABLE public.platform_job_queue (
    job_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id uuid NOT NULL,
    account_id uuid REFERENCES public.marketplace_accounts(marketplace_account_id) ON DELETE CASCADE,
    job_type text NOT NULL, -- e.g. sync_orders, sync_stock
    payload jsonb,
    status text DEFAULT 'pending' NOT NULL, -- pending, running, completed, failed
    priority int DEFAULT 10 NOT NULL, -- lower numbers = higher priority
    attempts int DEFAULT 0 NOT NULL,
    max_attempts int DEFAULT 3 NOT NULL,
    locked_at timestamp with time zone,
    locked_by text, -- worker identifier
    last_error text,
    run_after timestamp with time zone DEFAULT now() NOT NULL,
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp with time zone DEFAULT now()
);
CREATE INDEX idx_job_queue_fetch ON public.platform_job_queue(status, run_after, priority) WHERE (status = 'pending');
```

---

## 2. Dequeue Query (`FOR UPDATE SKIP LOCKED`)

To fetch the next available job without lock contention:
```sql
CREATE OR REPLACE FUNCTION public.dequeue_next_sync_job(
    p_worker_id text,
    p_lease_seconds int DEFAULT 300
)
RETURNS TABLE (
    job_id uuid,
    tenant_id uuid,
    account_id uuid,
    job_type text,
    payload jsonb
)
SECURITY DEFINER
AS $$
DECLARE
    v_target_job_id uuid;
BEGIN
    -- Select the highest priority job that is ready to run, filtering out suspended/inactive tenants
    SELECT q.job_id INTO v_target_job_id
    FROM public.platform_job_queue q
    JOIN public.tenant_subscriptions ts ON ts.tenant_id = q.tenant_id
    JOIN public.marketplace_accounts ma ON ma.marketplace_account_id = q.account_id
    WHERE q.status = 'pending'
      AND q.run_after <= now()
      -- Filter 1: Tenant must have active or trialing status
      AND ts.status IN ('trialing', 'active')
      AND ts.expires_at > now()
      -- Filter 2: Account must be connected
      AND ma.status = 'connected'
    ORDER BY q.priority ASC, q.created_at ASC
    LIMIT 1
    FOR UPDATE SKIP LOCKED;

    IF v_target_job_id IS NOT NULL THEN
        UPDATE public.platform_job_queue
        SET status = 'running',
            locked_at = now(),
            locked_by = p_worker_id,
            attempts = attempts + 1,
            run_after = now() + (p_lease_seconds || ' seconds')::interval,
            updated_at = now()
        WHERE platform_job_queue.job_id = v_target_job_id;

        RETURN QUERY
        SELECT q.job_id, q.tenant_id, q.account_id, q.job_type, q.payload
        FROM public.platform_job_queue q
        WHERE q.job_id = v_target_job_id;
    END IF;
END;
$$ LANGUAGE plpgsql;
```

---

## 3. Worker Integration Plan

1. **Service Role Integration**: The background sync runner/worker requests jobs by invoking `dequeue_next_sync_job('worker-node-1')`.
2. **Lease Renewal / Heartbeat**: If a job takes longer than 5 minutes, the worker should update `run_after` to extend the lease.
3. **Failures / Retries**: If the worker encounters an error, it calls a wrapper RPC `report_job_failure(job_id, error_msg)` which increments `attempts`, sets the status back to `pending`, and schedules `run_after` with exponential backoff. If `attempts >= max_attempts`, the job status changes to `failed`.
