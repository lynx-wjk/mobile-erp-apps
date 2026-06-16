-- Subscription entitlement runtime foundation.
-- 1) Seed wjk-group as internal/full feature plan.
-- 2) Add tenant_entitlement_snapshot_for_app() for Flutter plan guards.
-- Safe/idempotent. Does not change starter feature matrix.

begin;

insert into public.subscription_plan_features (
  plan_id,
  feature_key,
  enabled,
  limit_value,
  config
)
select
  sp.plan_id,
  fc.feature_key,
  true as enabled,
  null::integer as limit_value,
  '{}'::jsonb as config
from public.subscription_plans sp
cross join public.feature_catalog fc
where sp.plan_code = 'wjk-group'
  and coalesce(fc.is_active, true) = true
on conflict (plan_id, feature_key)
do update set
  enabled = true,
  config = coalesce(public.subscription_plan_features.config, '{}'::jsonb);

create or replace function public.tenant_entitlement_snapshot_for_app()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id uuid := auth.uid();
  v_user record;
  v_sub record;
  v_features jsonb := '{}'::jsonb;
  v_feature_enabled jsonb := '{}'::jsonb;
  v_feature_limits jsonb := '{}'::jsonb;
  v_quotas jsonb := '{}'::jsonb;
begin
  if v_user_id is null then
    return jsonb_build_object(
      'ok', false,
      'reason', 'auth_uid_missing',
      'features', '{}'::jsonb,
      'feature_enabled', '{}'::jsonb,
      'feature_limits', '{}'::jsonb,
      'quotas', '{}'::jsonb
    );
  end if;

  select
    u.user_id,
    u.email,
    u.nama,
    u.username,
    lower(coalesce(u.role_id, '')) as role_id,
    coalesce(u.status, 'active') as status,
    u.tenant_id
  into v_user
  from public.users u
  where u.user_id = v_user_id
  limit 1;

  if v_user.user_id is null then
    return jsonb_build_object(
      'ok', false,
      'reason', 'app_user_not_found',
      'user_id', v_user_id,
      'features', '{}'::jsonb,
      'feature_enabled', '{}'::jsonb,
      'feature_limits', '{}'::jsonb,
      'quotas', '{}'::jsonb
    );
  end if;

  if v_user.status <> 'active' then
    return jsonb_build_object(
      'ok', false,
      'reason', 'app_user_inactive',
      'user_id', v_user.user_id,
      'tenant_id', v_user.tenant_id,
      'role_id', v_user.role_id,
      'features', '{}'::jsonb,
      'feature_enabled', '{}'::jsonb,
      'feature_limits', '{}'::jsonb,
      'quotas', '{}'::jsonb
    );
  end if;

  select
    ts.tenant_subscription_id,
    ts.tenant_id,
    ts.status as subscription_status,
    ts.trial_ends_at,
    ts.current_period_start,
    ts.current_period_end,
    sp.plan_id,
    sp.plan_code,
    sp.plan_name,
    sp.is_active as plan_is_active,
    sp.max_users,
    sp.max_marketplace_accounts,
    sp.max_shopee_accounts,
    sp.max_tiktok_accounts,
    sp.max_storage_mb,
    sp.max_order_retention_days
  into v_sub
  from public.tenant_subscriptions ts
  join public.subscription_plans sp on sp.plan_id = ts.plan_id
  where ts.tenant_id = v_user.tenant_id
    and ts.status in ('trialing', 'active')
    and (ts.current_period_start is null or ts.current_period_start <= now())
    and (ts.current_period_end is null or ts.current_period_end >= now())
  order by ts.created_at desc
  limit 1;

  select coalesce(
    jsonb_object_agg(
      fc.feature_key,
      jsonb_build_object(
        'enabled', coalesce((public.tenant_has_feature(fc.feature_key)->>'enabled')::boolean, false),
        'source', coalesce(public.tenant_has_feature(fc.feature_key)->>'source', 'none'),
        'reason', coalesce(public.tenant_has_feature(fc.feature_key)->>'reason', 'unknown'),
        'feature_group', fc.feature_group,
        'feature_name', fc.feature_name
      )
      order by fc.feature_group, fc.sort_order, fc.feature_key
    ),
    '{}'::jsonb
  )
  into v_features
  from public.feature_catalog fc
  where coalesce(fc.is_active, true) = true;

  select coalesce(
    jsonb_object_agg(
      x.feature_key,
      x.enabled
      order by x.feature_key
    ),
    '{}'::jsonb
  )
  into v_feature_enabled
  from (
    select
      fc.feature_key,
      coalesce((public.tenant_has_feature(fc.feature_key)->>'enabled')::boolean, false) as enabled
    from public.feature_catalog fc
    where coalesce(fc.is_active, true) = true
  ) x;

  if v_sub.plan_id is not null then
    select coalesce(
      jsonb_object_agg(
        spf.feature_key,
        coalesce(ov.limit_value, spf.limit_value)
        order by spf.feature_key
      ),
      '{}'::jsonb
    )
    into v_feature_limits
    from public.subscription_plan_features spf
    left join lateral (
      select tso.limit_value
      from public.tenant_subscription_overrides tso
      where tso.tenant_id = v_user.tenant_id
        and tso.feature_key = spf.feature_key
        and tso.override_type = 'limit'
        and tso.starts_at <= now()
        and (tso.ends_at is null or tso.ends_at > now())
      order by tso.created_at desc
      limit 1
    ) ov on true
    where spf.plan_id = v_sub.plan_id;
  end if;

  v_quotas := jsonb_build_object(
    'max_users', coalesce(v_sub.max_users, 0),
    'max_marketplace_accounts', coalesce(v_sub.max_marketplace_accounts, 0),
    'max_shopee_accounts', coalesce(v_sub.max_shopee_accounts, 0),
    'max_tiktok_accounts', coalesce(v_sub.max_tiktok_accounts, 0),
    'max_storage_mb', coalesce(v_sub.max_storage_mb, 0),
    'max_order_retention_days', coalesce(v_sub.max_order_retention_days, 0)
  );

  return jsonb_build_object(
    'ok', true,
    'user_id', v_user.user_id,
    'tenant_id', v_user.tenant_id,
    'role_id', v_user.role_id,
    'is_platform_owner', v_user.role_id = 'platform_owner',
    'subscription', jsonb_build_object(
      'tenant_subscription_id', v_sub.tenant_subscription_id,
      'status', coalesce(v_sub.subscription_status, 'unassigned'),
      'plan_id', v_sub.plan_id,
      'plan_code', coalesce(v_sub.plan_code, 'unassigned'),
      'plan_name', coalesce(v_sub.plan_name, 'Unassigned'),
      'plan_is_active', coalesce(v_sub.plan_is_active, false),
      'trial_ends_at', v_sub.trial_ends_at,
      'current_period_start', v_sub.current_period_start,
      'current_period_end', v_sub.current_period_end
    ),
    'features', v_features,
    'feature_enabled', v_feature_enabled,
    'feature_limits', coalesce(v_feature_limits, '{}'::jsonb),
    'quotas', v_quotas
  );
end;
$$;

revoke all on function public.tenant_entitlement_snapshot_for_app() from public;
revoke all on function public.tenant_entitlement_snapshot_for_app() from anon;
grant execute on function public.tenant_entitlement_snapshot_for_app() to authenticated;

commit;
