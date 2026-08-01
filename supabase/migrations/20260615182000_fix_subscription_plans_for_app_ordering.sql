-- Fix list_subscription_plans_for_app ordering inside jsonb_agg.
-- Root cause: query-level ORDER BY sp.sort_order on aggregate query triggers SQLSTATE 42803.

CREATE OR REPLACE FUNCTION public.list_subscription_plans_for_app()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
declare
  v_plans jsonb;
begin
  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'plan_id', sp.plan_id,
        'plan_code', sp.plan_code,
        'plan_name', sp.plan_name,
        'description', sp.description,
        'billing_period', sp.billing_period,
        'price_amount', sp.price_amount,
        'currency', sp.currency,
        'max_users', sp.max_users,
        'max_marketplace_accounts', sp.max_marketplace_accounts,
        'max_shopee_accounts', sp.max_shopee_accounts,
        'max_tiktok_accounts', sp.max_tiktok_accounts,
        'max_storage_mb', sp.max_storage_mb,
        'max_order_retention_days', sp.max_order_retention_days,
        'is_trial', sp.is_trial,
        'features', coalesce((
          select jsonb_agg(spf.feature_key order by spf.feature_key)
          from public.subscription_plan_features spf
          where spf.plan_id = sp.plan_id
            and spf.enabled = true
        ), '[]'::jsonb)
      )
      order by sp.sort_order nulls last, sp.plan_code
    ),
    '[]'::jsonb
  )
  into v_plans
  from public.subscription_plans sp
  where sp.is_active = true;

  return jsonb_build_object(
    'ok', true,
    'plans', v_plans
  );
end;
$$;

ALTER FUNCTION public.list_subscription_plans_for_app() OWNER TO postgres;

REVOKE ALL ON FUNCTION public.list_subscription_plans_for_app() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.list_subscription_plans_for_app() TO authenticated;
GRANT EXECUTE ON FUNCTION public.list_subscription_plans_for_app() TO service_role;