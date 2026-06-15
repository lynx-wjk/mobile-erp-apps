-- Migration: 20260615180000_phase7_subscription_lifecycle.sql
-- Goal: Create subscription lifecycle maintenance RPC.
-- Canonical unversioned name: run_subscription_lifecycle_maintenance
-- Canonical unversioned helper: preview_subscription_lifecycle_maintenance
-- Rules:
-- * SECURITY DEFINER
-- * search_path = public
-- * No cron, no automatic suspension of tenants, no data purge, no UI block.

CREATE OR REPLACE FUNCTION public.run_subscription_lifecycle_maintenance(
  p_dry_run boolean default true,
  p_now timestamptz default now()
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
declare
  v_is_platform_owner boolean;
  v_candidate record;
  v_candidates_json jsonb := '[]'::jsonb;
  v_trial_expired integer := 0;
  v_active_past_due integer := 0;
  v_past_due_suspended integer := 0;
  v_canceled_expired integer := 0;
  v_total_candidates integer := 0;
  v_total_applied integer := 0;
  v_actor_id uuid;
begin
  -- 1. Check permissions
  v_is_platform_owner := public.app_is_platform_owner();
  
  -- If dry run is false, strictly require platform owner
  if not p_dry_run then
    if not coalesce(v_is_platform_owner, false) then
      return jsonb_build_object(
        'ok', false,
        'error', 'forbidden',
        'message', 'Only platform owners can execute subscription lifecycle maintenance.'
      );
    end if;
  else
    -- If dry run is true, restrict to platform owner or service role
    if not coalesce(v_is_platform_owner, false) and coalesce(auth.role(), '') <> 'service_role' then
      return jsonb_build_object(
        'ok', false,
        'error', 'forbidden',
        'message', 'Access denied.'
      );
    end if;
  end if;

  v_actor_id := auth.uid();

  -- 2. Loop through candidates
  for v_candidate in (
    select ts.tenant_subscription_id, ts.tenant_id, ts.plan_id, ts.status as old_status,
           ts.trial_ends_at, ts.current_period_end, ts.grace_until,
           case 
             when ts.status = 'trialing' then 'expired'
             when ts.status = 'active' then 'past_due'
             when ts.status = 'past_due' then 'suspended'
             when ts.status = 'canceled' then 'expired'
           end as new_status
    from public.tenant_subscriptions ts
    where (ts.status = 'trialing' and ts.trial_ends_at is not null and ts.trial_ends_at < p_now)
       or (ts.status = 'active' and ts.current_period_end is not null and ts.current_period_end < p_now and (ts.grace_until is null or ts.grace_until < p_now))
       or (ts.status = 'past_due' and ts.grace_until is not null and ts.grace_until < p_now)
       or (ts.status = 'canceled' and ts.current_period_end is not null and ts.current_period_end < p_now)
  ) loop
    v_total_candidates := v_total_candidates + 1;

    -- Track metrics
    if v_candidate.old_status = 'trialing' then
      v_trial_expired := v_trial_expired + 1;
    elsif v_candidate.old_status = 'active' then
      v_active_past_due := v_active_past_due + 1;
    elsif v_candidate.old_status = 'past_due' then
      v_past_due_suspended := v_past_due_suspended + 1;
    elsif v_candidate.old_status = 'canceled' then
      v_canceled_expired := v_canceled_expired + 1;
    end if;

    -- Append to candidates JSON list
    v_candidates_json := v_candidates_json || jsonb_build_array(
      jsonb_build_object(
        'tenant_subscription_id', v_candidate.tenant_subscription_id,
        'tenant_id', v_candidate.tenant_id,
        'plan_id', v_candidate.plan_id,
        'old_status', v_candidate.old_status,
        'new_status', v_candidate.new_status,
        'details', jsonb_build_object(
          'trial_ends_at', v_candidate.trial_ends_at,
          'current_period_end', v_candidate.current_period_end,
          'grace_until', v_candidate.grace_until
        )
      )
    );

    -- Apply changes if dry run is false
    if not p_dry_run then
      -- Update tenant subscription status
      update public.tenant_subscriptions
      set status = v_candidate.new_status,
          suspended_at = case when v_candidate.new_status = 'suspended' then p_now else suspended_at end,
          canceled_at = case when v_candidate.new_status = 'expired' and v_candidate.old_status = 'canceled' then p_now else canceled_at end,
          updated_at = p_now,
          updated_by = coalesce(v_actor_id, updated_by)
      where tenant_subscription_id = v_candidate.tenant_subscription_id;

      -- Insert event log
      insert into public.tenant_subscription_events (
        tenant_id,
        tenant_subscription_id,
        event_type,
        old_status,
        new_status,
        old_plan_id,
        new_plan_id,
        payload,
        created_by,
        created_at
      )
      values (
        v_candidate.tenant_id,
        v_candidate.tenant_subscription_id,
        'lifecycle_transition',
        v_candidate.old_status,
        v_candidate.new_status,
        v_candidate.plan_id,
        v_candidate.plan_id,
        jsonb_build_object(
          'reason', 'lifecycle_maintenance_routine',
          'maintenance_time', p_now
        ),
        v_actor_id,
        p_now
      );

      v_total_applied := v_total_applied + 1;
    end if;

  end loop;

  return jsonb_build_object(
    'ok', true,
    'dry_run', p_dry_run,
    'now', p_now,
    'summary', jsonb_build_object(
      'trial_expired', v_trial_expired,
      'active_past_due', v_active_past_due,
      'past_due_suspended', v_past_due_suspended,
      'canceled_expired', v_canceled_expired,
      'total_candidates', v_total_candidates,
      'total_applied', v_total_applied
    ),
    'candidates', v_candidates_json
  );
end;
$$;

ALTER FUNCTION public.run_subscription_lifecycle_maintenance(boolean, timestamptz) OWNER TO postgres;

-- 3. Create preview_subscription_lifecycle_maintenance helper
CREATE OR REPLACE FUNCTION public.preview_subscription_lifecycle_maintenance(
  p_now timestamptz default now()
)
RETURNS jsonb
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $$
  select public.run_subscription_lifecycle_maintenance(true, p_now);
$$;

ALTER FUNCTION public.preview_subscription_lifecycle_maintenance(timestamptz) OWNER TO postgres;
