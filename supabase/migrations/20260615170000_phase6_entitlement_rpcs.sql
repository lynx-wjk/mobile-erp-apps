-- Migration: 20260615170000_phase6_entitlement_rpcs.sql
-- Goal: Create safe unversioned subscription entitlement RPCs.
-- No app blocking is active yet.

-- 1. Create app_is_platform_owner if it does not exist
CREATE OR REPLACE FUNCTION public.app_is_platform_owner()
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select exists (
    select 1
    from public.users u
    where u.user_id = auth.uid()
      and coalesce(u.status, 'active') = 'active'
      and u.role_id = 'platform_owner'
  );
$function$;

ALTER FUNCTION public.app_is_platform_owner() OWNER TO postgres;

-- 2. Create tenant_has_feature
CREATE OR REPLACE FUNCTION public.tenant_has_feature(p_feature_key text, p_tenant_id uuid default null)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
declare
  v_tenant_id uuid;
  v_is_platform_owner boolean;
  v_sub_row record;
  v_plan_enabled boolean;
  v_override_enabled boolean;
  v_enabled boolean;
  v_source text;
  v_reason text;
  v_plan_code text;
  v_status text;
begin
  -- Check if caller is platform owner
  v_is_platform_owner := public.app_is_platform_owner();

  -- Resolve tenant_id
  if p_tenant_id is not null and v_is_platform_owner then
    v_tenant_id := p_tenant_id;
  else
    v_tenant_id := public.app_current_tenant_id_or_default();
  end if;

  if v_tenant_id is null then
    return jsonb_build_object(
      'ok', true,
      'enabled', false,
      'source', 'none',
      'reason', 'tenant_not_found'
    );
  end if;

  -- Get active subscription (status in trialing or active, within period)
  select ts.*, sp.plan_code
  into v_sub_row
  from public.tenant_subscriptions ts
  join public.subscription_plans sp on ts.plan_id = sp.plan_id
  where ts.tenant_id = v_tenant_id
    and ts.status in ('trialing', 'active')
    and (ts.current_period_start is null or ts.current_period_start <= now())
    and (ts.current_period_end is null or ts.current_period_end >= now())
  order by ts.created_at desc
  limit 1;

  -- If no subscription found, return fallback features
  if v_sub_row.tenant_subscription_id is null then
    if p_feature_key in ('stock_basic', 'production_basic', 'finance_basic', 'invite_management') then
      v_enabled := true;
    else
      v_enabled := false;
    end if;

    return jsonb_build_object(
      'ok', true,
      'tenant_id', v_tenant_id,
      'feature_key', p_feature_key,
      'enabled', v_enabled,
      'source', 'fallback',
      'plan_code', 'unassigned',
      'subscription_status', 'unassigned',
      'reason', 'unassigned_fallback'
    );
  end if;

  v_plan_code := v_sub_row.plan_code;
  v_status := v_sub_row.status;

  -- Check plan features
  select enabled into v_plan_enabled
  from public.subscription_plan_features
  where plan_id = v_sub_row.plan_id
    and feature_key = p_feature_key;

  if found then
    v_enabled := v_plan_enabled;
    v_source := 'plan';
    v_reason := 'configured_in_plan';
  else
    v_enabled := false;
    v_source := 'none';
    v_reason := 'not_in_plan';
  end if;

  -- Check overrides (starts_at <= now() and (ends_at is null or ends_at > now()))
  select enabled into v_override_enabled
  from public.tenant_subscription_overrides
  where tenant_id = v_tenant_id
    and feature_key = p_feature_key
    and override_type = 'feature'
    and starts_at <= now()
    and (ends_at is null or ends_at > now())
  order by created_at desc
  limit 1;

  if found and v_override_enabled is not null then
    v_enabled := v_override_enabled;
    v_source := 'override';
    v_reason := 'feature_override_applied';
  end if;

  return jsonb_build_object(
    'ok', true,
    'tenant_id', v_tenant_id,
    'feature_key', p_feature_key,
    'enabled', v_enabled,
    'source', v_source,
    'plan_code', v_plan_code,
    'subscription_status', v_status,
    'reason', v_reason
  );
end;
$$;

ALTER FUNCTION public.tenant_has_feature(p_feature_key text, p_tenant_id uuid) OWNER TO postgres;

-- 3. Create get_my_entitlements
CREATE OR REPLACE FUNCTION public.get_my_entitlements()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
declare
  v_tenant_id uuid;
  v_sub_row record;
  v_entitlements jsonb := '{}'::jsonb;
  v_feature_rec record;
  v_override_enabled boolean;
  v_override_limit integer;
  v_override_config jsonb;
  v_enabled boolean;
  v_source text;
  v_limit_value integer;
  v_config jsonb;
  v_plan_json jsonb := null;
  v_sub_json jsonb := null;
  v_fallback boolean := false;
begin
  -- Resolve current tenant
  v_tenant_id := public.app_current_tenant_id_or_default();

  if v_tenant_id is null then
    return jsonb_build_object(
      'ok', true,
      'tenant_id', null,
      'plan', null,
      'subscription', null,
      'entitlements', '{}'::jsonb,
      'fallback', true
    );
  end if;

  -- Get active subscription
  select ts.*, sp.plan_code, sp.plan_name, sp.max_users, sp.max_marketplace_accounts,
         sp.max_shopee_accounts, sp.max_tiktok_accounts, sp.max_storage_mb, sp.max_order_retention_days
  into v_sub_row
  from public.tenant_subscriptions ts
  join public.subscription_plans sp on ts.plan_id = sp.plan_id
  where ts.tenant_id = v_tenant_id
    and ts.status in ('trialing', 'active')
    and (ts.current_period_start is null or ts.current_period_start <= now())
    and (ts.current_period_end is null or ts.current_period_end >= now())
  order by ts.created_at desc
  limit 1;

  -- Handle fallback if no active subscription exists
  if v_sub_row.tenant_subscription_id is null then
    v_fallback := true;
    v_entitlements := jsonb_build_object(
      'stock_basic', jsonb_build_object('enabled', true, 'source', 'fallback', 'limit_value', null, 'config', '{}'::jsonb),
      'production_basic', jsonb_build_object('enabled', true, 'source', 'fallback', 'limit_value', null, 'config', '{}'::jsonb),
      'finance_basic', jsonb_build_object('enabled', true, 'source', 'fallback', 'limit_value', null, 'config', '{}'::jsonb),
      'invite_management', jsonb_build_object('enabled', true, 'source', 'fallback', 'limit_value', null, 'config', '{}'::jsonb)
    );
    
    -- Exclude fallback features and set others to disabled
    for v_feature_rec in (
      select feature_key from public.feature_catalog 
      where feature_key not in ('stock_basic', 'production_basic', 'finance_basic', 'invite_management')
        and is_active = true
    ) loop
      v_entitlements := jsonb_set(
        v_entitlements, 
        array[v_feature_rec.feature_key], 
        jsonb_build_object('enabled', false, 'source', 'fallback', 'limit_value', null, 'config', '{}'::jsonb)
      );
    end loop;
  else
    -- Build plan and subscription JSON summaries
    v_plan_json := jsonb_build_object(
      'plan_id', v_sub_row.plan_id,
      'plan_code', v_sub_row.plan_code,
      'plan_name', v_sub_row.plan_name,
      'max_users', v_sub_row.max_users,
      'max_marketplace_accounts', v_sub_row.max_marketplace_accounts,
      'max_shopee_accounts', v_sub_row.max_shopee_accounts,
      'max_tiktok_accounts', v_sub_row.max_tiktok_accounts,
      'max_storage_mb', v_sub_row.max_storage_mb,
      'max_order_retention_days', v_sub_row.max_order_retention_days
    );

    v_sub_json := jsonb_build_object(
      'tenant_subscription_id', v_sub_row.tenant_subscription_id,
      'status', v_sub_row.status,
      'started_at', v_sub_row.started_at,
      'trial_ends_at', v_sub_row.trial_ends_at,
      'current_period_start', v_sub_row.current_period_start,
      'current_period_end', v_sub_row.current_period_end
    );

    -- Loop through all active features in the catalog and construct entitlements
    for v_feature_rec in (
      select fc.feature_key, spf.enabled as plan_enabled, spf.limit_value as plan_limit, spf.config as plan_config
      from public.feature_catalog fc
      left join public.subscription_plan_features spf on spf.plan_id = v_sub_row.plan_id and spf.feature_key = fc.feature_key
      where fc.is_active = true
    ) loop
      v_enabled := coalesce(v_feature_rec.plan_enabled, false);
      v_limit_value := v_feature_rec.plan_limit;
      v_config := coalesce(v_feature_rec.plan_config, '{}'::jsonb);
      v_source := case when v_feature_rec.plan_enabled is not null then 'plan' else 'none' end;

      -- Apply feature override
      select enabled into v_override_enabled
      from public.tenant_subscription_overrides
      where tenant_id = v_tenant_id
        and feature_key = v_feature_rec.feature_key
        and override_type = 'feature'
        and starts_at <= now()
        and (ends_at is null or ends_at > now())
      order by created_at desc
      limit 1;

      if found and v_override_enabled is not null then
        v_enabled := v_override_enabled;
        v_source := 'override';
      end if;

      -- Apply limit override
      select limit_value into v_override_limit
      from public.tenant_subscription_overrides
      where tenant_id = v_tenant_id
        and feature_key = v_feature_rec.feature_key
        and override_type = 'limit'
        and starts_at <= now()
        and (ends_at is null or ends_at > now())
      order by created_at desc
      limit 1;

      if found and v_override_limit is not null then
        v_limit_value := v_override_limit;
        v_source := 'override';
      end if;

      -- Apply config override
      select config into v_override_config
      from public.tenant_subscription_overrides
      where tenant_id = v_tenant_id
        and feature_key = v_feature_rec.feature_key
        and override_type = 'config'
        and starts_at <= now()
        and (ends_at is null or ends_at > now())
      order by created_at desc
      limit 1;

      if found and v_override_config is not null then
        v_config := v_override_config;
        v_source := 'override';
      end if;

      -- Add feature record to entitlements jsonb
      v_entitlements := jsonb_set(
        v_entitlements,
        array[v_feature_rec.feature_key],
        jsonb_build_object(
          'enabled', v_enabled,
          'source', v_source,
          'limit_value', v_limit_value,
          'config', v_config
        )
      );
    end loop;
  end if;

  return jsonb_build_object(
    'ok', true,
    'tenant_id', v_tenant_id,
    'plan', v_plan_json,
    'subscription', v_sub_json,
    'entitlements', v_entitlements,
    'fallback', v_fallback
  );
end;
$$;

ALTER FUNCTION public.get_my_entitlements() OWNER TO postgres;

-- 4. Create platform_tenant_subscription_set
CREATE OR REPLACE FUNCTION public.platform_tenant_subscription_set(
   p_tenant_id uuid,
   p_plan_code text,
   p_status text default 'active',
   p_trial_ends_at timestamptz default null,
   p_current_period_start timestamptz default now(),
   p_current_period_end timestamptz default null,
   p_notes text default null
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
declare
  v_is_platform_owner boolean;
  v_new_plan_id uuid;
  v_new_plan_active boolean;
  v_old_sub_id uuid;
  v_old_status text;
  v_old_plan_id uuid;
  v_new_sub_id uuid;
  v_actor_id uuid;
begin
  -- 1. Check platform owner permissions
  v_is_platform_owner := public.app_is_platform_owner();
  if not coalesce(v_is_platform_owner, false) then
    return jsonb_build_object(
      'ok', false,
      'error', 'forbidden',
      'message', 'Only platform owners can manage subscriptions.'
    );
  end if;

  -- 2. Validate tenant exists
  if not exists (
    select 1 from public.app_tenants where tenant_id = p_tenant_id
  ) then
    return jsonb_build_object(
      'ok', false,
      'error', 'tenant_not_found',
      'message', 'The specified tenant does not exist.'
    );
  end if;

  -- 3. Validate plan exists and is active
  select plan_id, is_active into v_new_plan_id, v_new_plan_active
  from public.subscription_plans
  where plan_code = p_plan_code;

  if v_new_plan_id is null then
    return jsonb_build_object(
      'ok', false,
      'error', 'plan_not_found',
      'message', 'The specified plan code does not exist.'
    );
  end if;

  if not coalesce(v_new_plan_active, false) then
    return jsonb_build_object(
      'ok', false,
      'error', 'plan_inactive',
      'message', 'The specified plan is currently inactive.'
    );
  end if;

  -- Validate status parameter
  if p_status not in ('trialing', 'active', 'past_due', 'suspended', 'canceled', 'expired') then
    return jsonb_build_object(
      'ok', false,
      'error', 'invalid_status',
      'message', 'The status must be one of: trialing, active, past_due, suspended, canceled, expired.'
    );
  end if;

  -- Get actor user ID
  v_actor_id := auth.uid();

  -- Get current subscription details for event logging
  select tenant_subscription_id, status, plan_id
  into v_old_sub_id, v_old_status, v_old_plan_id
  from public.tenant_subscriptions
  where tenant_id = p_tenant_id
  order by created_at desc
  limit 1;

  -- Expire previous active/trialing subscriptions
  if v_old_sub_id is not null then
    update public.tenant_subscriptions
    set status = 'expired',
        updated_by = v_actor_id,
        updated_at = now()
    where tenant_id = p_tenant_id
      and status in ('trialing', 'active');
  end if;

  -- Insert new tenant subscription record
  insert into public.tenant_subscriptions (
    tenant_id,
    plan_id,
    status,
    started_at,
    trial_ends_at,
    current_period_start,
    current_period_end,
    notes,
    created_by,
    updated_by
  )
  values (
    p_tenant_id,
    v_new_plan_id,
    p_status,
    now(),
    p_trial_ends_at,
    p_current_period_start,
    p_current_period_end,
    p_notes,
    v_actor_id,
    v_actor_id
  )
  returning tenant_subscription_id into v_new_sub_id;

  -- Insert tenant subscription event
  insert into public.tenant_subscription_events (
    tenant_id,
    tenant_subscription_id,
    event_type,
    old_status,
    new_status,
    old_plan_id,
    new_plan_id,
    payload,
    created_by
  )
  values (
    p_tenant_id,
    v_new_sub_id,
    'subscription_updated',
    v_old_status,
    p_status,
    v_old_plan_id,
    v_new_plan_id,
    jsonb_build_object(
      'notes', p_notes,
      'trial_ends_at', p_trial_ends_at,
      'current_period_start', p_current_period_start,
      'current_period_end', p_current_period_end
    ),
    v_actor_id
  );

  return jsonb_build_object(
    'ok', true,
    'tenant_subscription_id', v_new_sub_id,
    'tenant_id', p_tenant_id,
    'plan_code', p_plan_code,
    'status', p_status
  );
end;
$$;

ALTER FUNCTION public.platform_tenant_subscription_set(uuid, text, text, timestamptz, timestamptz, timestamptz, text) OWNER TO postgres;

-- 5. Create platform_tenant_subscription_override_set
CREATE OR REPLACE FUNCTION public.platform_tenant_subscription_override_set(
   p_tenant_id uuid,
   p_feature_key text,
   p_override_type text,
   p_enabled boolean default null,
   p_limit_value integer default null,
   p_config jsonb default '{}'::jsonb,
   p_reason text default null,
   p_ends_at timestamptz default null
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
declare
  v_is_platform_owner boolean;
  v_actor_id uuid;
  v_override_id uuid;
begin
  -- 1. Check platform owner permissions
  v_is_platform_owner := public.app_is_platform_owner();
  if not coalesce(v_is_platform_owner, false) then
    return jsonb_build_object(
      'ok', false,
      'error', 'forbidden',
      'message', 'Only platform owners can set overrides.'
    );
  end if;

  -- 2. Validate tenant exists
  if not exists (
    select 1 from public.app_tenants where tenant_id = p_tenant_id
  ) then
    return jsonb_build_object(
      'ok', false,
      'error', 'tenant_not_found',
      'message', 'The specified tenant does not exist.'
    );
  end if;

  -- 3. Validate feature_key exists
  if not exists (
    select 1 from public.feature_catalog where feature_key = p_feature_key
  ) then
    return jsonb_build_object(
      'ok', false,
      'error', 'feature_not_found',
      'message', 'The specified feature key does not exist.'
    );
  end if;

  -- 4. Validate override_type
  if p_override_type not in ('feature', 'limit', 'config') then
    return jsonb_build_object(
      'ok', false,
      'error', 'invalid_override_type',
      'message', 'The override type must be one of: feature, limit, config.'
    );
  end if;

  -- Get actor user ID
  v_actor_id := auth.uid();

  -- Insert override
  insert into public.tenant_subscription_overrides (
    tenant_id,
    feature_key,
    override_type,
    enabled,
    limit_value,
    config,
    reason,
    starts_at,
    ends_at,
    created_by
  )
  values (
    p_tenant_id,
    p_feature_key,
    p_override_type,
    p_enabled,
    p_limit_value,
    p_config,
    p_reason,
    now(),
    p_ends_at,
    v_actor_id
  )
  returning override_id into v_override_id;

  -- Insert event
  insert into public.tenant_subscription_events (
    tenant_id,
    event_type,
    payload,
    created_by
  )
  values (
    p_tenant_id,
    'override_created',
    jsonb_build_object(
      'override_id', v_override_id,
      'feature_key', p_feature_key,
      'override_type', p_override_type,
      'enabled', p_enabled,
      'limit_value', p_limit_value,
      'config', p_config,
      'reason', p_reason,
      'ends_at', p_ends_at
    ),
    v_actor_id
  );

  return jsonb_build_object(
    'ok', true,
    'override_id', v_override_id,
    'tenant_id', p_tenant_id,
    'feature_key', p_feature_key,
    'override_type', p_override_type
  );
end;
$$;

ALTER FUNCTION public.platform_tenant_subscription_override_set(uuid, text, text, boolean, integer, jsonb, text, timestamptz) OWNER TO postgres;
