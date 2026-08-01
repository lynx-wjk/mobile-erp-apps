-- Auto-seed subscription feature matrix.
-- New subscription plans immediately get all active feature_catalog rows.
-- New feature_catalog rows immediately appear in all plans.
-- Normal plans default disabled for safety.
-- wjk-group defaults enabled as internal/full plan.

begin;

create or replace function public.subscription_plan_features_seed_for_plan(
  p_plan_id uuid
)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_plan_code text;
  v_inserted integer := 0;
begin
  select plan_code
  into v_plan_code
  from public.subscription_plans
  where plan_id = p_plan_id
  limit 1;

  if p_plan_id is null or v_plan_code is null then
    return 0;
  end if;

  insert into public.subscription_plan_features (
    plan_id,
    feature_key,
    enabled,
    limit_value,
    config
  )
  select
    p_plan_id,
    fc.feature_key,
    case when v_plan_code = 'wjk-group' then true else false end,
    null::integer,
    '{}'::jsonb
  from public.feature_catalog fc
  where coalesce(fc.is_active, true) = true
  on conflict (plan_id, feature_key)
  do nothing;

  get diagnostics v_inserted = row_count;
  return v_inserted;
end;
$$;

create or replace function public.subscription_plan_features_seed_all_missing()
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_inserted integer := 0;
begin
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
    case when sp.plan_code = 'wjk-group' then true else false end,
    null::integer,
    '{}'::jsonb
  from public.subscription_plans sp
  cross join public.feature_catalog fc
  where coalesce(fc.is_active, true) = true
  on conflict (plan_id, feature_key)
  do nothing;

  get diagnostics v_inserted = row_count;
  return v_inserted;
end;
$$;

create or replace function public.subscription_plan_features_after_plan_insert()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public.subscription_plan_features_seed_for_plan(new.plan_id);
  return new;
end;
$$;

drop trigger if exists trg_subscription_plan_features_after_plan_insert
on public.subscription_plans;

create trigger trg_subscription_plan_features_after_plan_insert
after insert on public.subscription_plans
for each row
execute function public.subscription_plan_features_after_plan_insert();

create or replace function public.subscription_plan_features_after_feature_insert()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if coalesce(new.is_active, true) = true then
    insert into public.subscription_plan_features (
      plan_id,
      feature_key,
      enabled,
      limit_value,
      config
    )
    select
      sp.plan_id,
      new.feature_key,
      case when sp.plan_code = 'wjk-group' then true else false end,
      null::integer,
      '{}'::jsonb
    from public.subscription_plans sp
    on conflict (plan_id, feature_key)
    do nothing;
  end if;

  return new;
end;
$$;

drop trigger if exists trg_subscription_plan_features_after_feature_insert
on public.feature_catalog;

create trigger trg_subscription_plan_features_after_feature_insert
after insert on public.feature_catalog
for each row
execute function public.subscription_plan_features_after_feature_insert();

select public.subscription_plan_features_seed_all_missing();

revoke all on function public.subscription_plan_features_seed_for_plan(uuid) from public;
revoke all on function public.subscription_plan_features_seed_all_missing() from public;
grant execute on function public.subscription_plan_features_seed_for_plan(uuid) to authenticated;
grant execute on function public.subscription_plan_features_seed_all_missing() to authenticated;

commit;
