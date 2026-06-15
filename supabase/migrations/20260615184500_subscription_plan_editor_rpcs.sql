-- Phase 6C-C1: Platform Owner subscription plan editor RPCs.
-- Scope:
-- - Add safe platform-owner-only RPCs for plan editor UI.
-- - Include inactive plans in editor snapshot.
-- - Allow upsert/update plan metadata and feature mapping.
-- - No plan deletion.
-- - Do not change entitlement enforcement.
-- - Do not change marketplace/finance/cron behavior.

BEGIN;

CREATE OR REPLACE FUNCTION public.platform_subscription_plan_editor_snapshot()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_is_platform_owner boolean;
  v_plans jsonb;
  v_features jsonb;
BEGIN
  SELECT EXISTS (
    SELECT 1
    FROM public.users u
    WHERE u.user_id = auth.uid()
      AND u.role_id = 'platform_owner'
      AND COALESCE(u.status, 'active') = 'active'
  )
  INTO v_is_platform_owner;

  IF NOT v_is_platform_owner THEN
    RETURN jsonb_build_object(
      'ok', false,
      'error', 'forbidden',
      'message', 'Only active platform_owner users can edit subscription plans.'
    );
  END IF;

  SELECT COALESCE(
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
        'is_active', sp.is_active,
        'sort_order', sp.sort_order,
        'features', COALESCE(
          (
            SELECT jsonb_agg(
              jsonb_build_object(
                'feature_key', fc.feature_key,
                'feature_name', fc.feature_name,
                'public_label', COALESCE(NULLIF(fc.public_label, ''), fc.feature_name),
                'feature_group', fc.feature_group,
                'is_client_visible', fc.is_client_visible,
                'enabled', COALESCE(spf.enabled, false),
                'limit_value', spf.limit_value,
                'config', COALESCE(spf.config, '{}'::jsonb),
                'sort_order', fc.sort_order
              )
              ORDER BY fc.sort_order, fc.feature_key
            )
            FROM public.feature_catalog fc
            LEFT JOIN public.subscription_plan_features spf
              ON spf.plan_id = sp.plan_id
             AND spf.feature_key = fc.feature_key
            WHERE fc.is_active = true
          ),
          '[]'::jsonb
        )
      )
      ORDER BY sp.sort_order, sp.plan_code
    ),
    '[]'::jsonb
  )
  INTO v_plans
  FROM public.subscription_plans sp;

  SELECT COALESCE(
    jsonb_agg(
      jsonb_build_object(
        'feature_key', fc.feature_key,
        'feature_name', fc.feature_name,
        'public_label', COALESCE(NULLIF(fc.public_label, ''), fc.feature_name),
        'public_description', COALESCE(NULLIF(fc.public_description, ''), fc.description, fc.feature_name),
        'feature_group', fc.feature_group,
        'is_client_visible', fc.is_client_visible,
        'sort_order', fc.sort_order
      )
      ORDER BY fc.sort_order, fc.feature_key
    ),
    '[]'::jsonb
  )
  INTO v_features
  FROM public.feature_catalog fc
  WHERE fc.is_active = true;

  RETURN jsonb_build_object(
    'ok', true,
    'version', 'phase_6c_c1_plan_editor_snapshot',
    'plans', v_plans,
    'features', v_features
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.platform_subscription_plan_upsert(
  p_plan_code text,
  p_plan_name text,
  p_description text DEFAULT NULL,
  p_billing_period text DEFAULT 'monthly',
  p_price_amount numeric DEFAULT 0,
  p_currency text DEFAULT 'IDR',
  p_max_users integer DEFAULT NULL,
  p_max_marketplace_accounts integer DEFAULT NULL,
  p_max_shopee_accounts integer DEFAULT NULL,
  p_max_tiktok_accounts integer DEFAULT NULL,
  p_max_storage_mb integer DEFAULT NULL,
  p_max_order_retention_days integer DEFAULT 90,
  p_is_trial boolean DEFAULT false,
  p_is_active boolean DEFAULT true,
  p_sort_order integer DEFAULT 0
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_is_platform_owner boolean;
  v_plan_code text;
  v_plan_id uuid;
BEGIN
  SELECT EXISTS (
    SELECT 1
    FROM public.users u
    WHERE u.user_id = auth.uid()
      AND u.role_id = 'platform_owner'
      AND COALESCE(u.status, 'active') = 'active'
  )
  INTO v_is_platform_owner;

  IF NOT v_is_platform_owner THEN
    RETURN jsonb_build_object('ok', false, 'error', 'forbidden', 'message', 'Only active platform_owner users can edit subscription plans.');
  END IF;

  v_plan_code := lower(trim(COALESCE(p_plan_code, '')));

  IF v_plan_code = '' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_plan_code', 'message', 'plan_code is required.');
  END IF;

  IF trim(COALESCE(p_plan_name, '')) = '' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_plan_name', 'message', 'plan_name is required.');
  END IF;

  IF COALESCE(p_price_amount, 0) < 0 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_price', 'message', 'price_amount cannot be negative.');
  END IF;

  IF COALESCE(p_max_order_retention_days, 90) < 1 OR COALESCE(p_max_order_retention_days, 90) > 90 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_retention', 'message', 'max_order_retention_days must be between 1 and 90.');
  END IF;

  INSERT INTO public.subscription_plans (
    plan_code,
    plan_name,
    description,
    billing_period,
    price_amount,
    currency,
    max_users,
    max_marketplace_accounts,
    max_shopee_accounts,
    max_tiktok_accounts,
    max_storage_mb,
    max_order_retention_days,
    is_trial,
    is_active,
    sort_order
  )
  VALUES (
    v_plan_code,
    trim(p_plan_name),
    NULLIF(trim(COALESCE(p_description, '')), ''),
    COALESCE(NULLIF(trim(COALESCE(p_billing_period, 'monthly')), ''), 'monthly'),
    COALESCE(p_price_amount, 0),
    COALESCE(NULLIF(upper(trim(COALESCE(p_currency, 'IDR'))), ''), 'IDR'),
    p_max_users,
    p_max_marketplace_accounts,
    p_max_shopee_accounts,
    p_max_tiktok_accounts,
    p_max_storage_mb,
    COALESCE(p_max_order_retention_days, 90),
    COALESCE(p_is_trial, false),
    COALESCE(p_is_active, true),
    COALESCE(p_sort_order, 0)
  )
  ON CONFLICT (plan_code) DO UPDATE
  SET
    plan_name = EXCLUDED.plan_name,
    description = EXCLUDED.description,
    billing_period = EXCLUDED.billing_period,
    price_amount = EXCLUDED.price_amount,
    currency = EXCLUDED.currency,
    max_users = EXCLUDED.max_users,
    max_marketplace_accounts = EXCLUDED.max_marketplace_accounts,
    max_shopee_accounts = EXCLUDED.max_shopee_accounts,
    max_tiktok_accounts = EXCLUDED.max_tiktok_accounts,
    max_storage_mb = EXCLUDED.max_storage_mb,
    max_order_retention_days = EXCLUDED.max_order_retention_days,
    is_trial = EXCLUDED.is_trial,
    is_active = EXCLUDED.is_active,
    sort_order = EXCLUDED.sort_order,
    updated_at = now()
  RETURNING plan_id
  INTO v_plan_id;

  RETURN jsonb_build_object(
    'ok', true,
    'plan_id', v_plan_id,
    'plan_code', v_plan_code,
    'message', 'Subscription plan saved.'
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.platform_subscription_plan_feature_set(
  p_plan_code text,
  p_feature_key text,
  p_enabled boolean DEFAULT true,
  p_limit_value integer DEFAULT NULL,
  p_config jsonb DEFAULT '{}'::jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_is_platform_owner boolean;
  v_plan_id uuid;
  v_plan_code text;
  v_feature_key text;
BEGIN
  SELECT EXISTS (
    SELECT 1
    FROM public.users u
    WHERE u.user_id = auth.uid()
      AND u.role_id = 'platform_owner'
      AND COALESCE(u.status, 'active') = 'active'
  )
  INTO v_is_platform_owner;

  IF NOT v_is_platform_owner THEN
    RETURN jsonb_build_object('ok', false, 'error', 'forbidden', 'message', 'Only active platform_owner users can edit plan features.');
  END IF;

  v_plan_code := lower(trim(COALESCE(p_plan_code, '')));
  v_feature_key := trim(COALESCE(p_feature_key, ''));

  SELECT sp.plan_id
  INTO v_plan_id
  FROM public.subscription_plans sp
  WHERE sp.plan_code = v_plan_code;

  IF v_plan_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'plan_not_found', 'message', 'Plan not found.');
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.feature_catalog fc
    WHERE fc.feature_key = v_feature_key
      AND fc.is_active = true
  ) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'feature_not_found', 'message', 'Feature not found.');
  END IF;

  INSERT INTO public.subscription_plan_features (
    plan_id,
    feature_key,
    enabled,
    limit_value,
    config
  )
  VALUES (
    v_plan_id,
    v_feature_key,
    COALESCE(p_enabled, false),
    p_limit_value,
    COALESCE(p_config, '{}'::jsonb)
  )
  ON CONFLICT (plan_id, feature_key) DO UPDATE
  SET
    enabled = EXCLUDED.enabled,
    limit_value = EXCLUDED.limit_value,
    config = EXCLUDED.config;

  RETURN jsonb_build_object(
    'ok', true,
    'plan_code', v_plan_code,
    'feature_key', v_feature_key,
    'enabled', COALESCE(p_enabled, false),
    'message', 'Subscription plan feature saved.'
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.platform_subscription_plan_set_active(
  p_plan_code text,
  p_is_active boolean
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_is_platform_owner boolean;
  v_plan_code text;
  v_plan_id uuid;
BEGIN
  SELECT EXISTS (
    SELECT 1
    FROM public.users u
    WHERE u.user_id = auth.uid()
      AND u.role_id = 'platform_owner'
      AND COALESCE(u.status, 'active') = 'active'
  )
  INTO v_is_platform_owner;

  IF NOT v_is_platform_owner THEN
    RETURN jsonb_build_object('ok', false, 'error', 'forbidden', 'message', 'Only active platform_owner users can change plan status.');
  END IF;

  v_plan_code := lower(trim(COALESCE(p_plan_code, '')));

  UPDATE public.subscription_plans
  SET
    is_active = COALESCE(p_is_active, false),
    updated_at = now()
  WHERE plan_code = v_plan_code
  RETURNING plan_id
  INTO v_plan_id;

  IF v_plan_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'plan_not_found', 'message', 'Plan not found.');
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'plan_code', v_plan_code,
    'is_active', COALESCE(p_is_active, false),
    'message', 'Subscription plan status updated.'
  );
END;
$$;

ALTER FUNCTION public.platform_subscription_plan_editor_snapshot() OWNER TO postgres;
ALTER FUNCTION public.platform_subscription_plan_upsert(text, text, text, text, numeric, text, integer, integer, integer, integer, integer, integer, boolean, boolean, integer) OWNER TO postgres;
ALTER FUNCTION public.platform_subscription_plan_feature_set(text, text, boolean, integer, jsonb) OWNER TO postgres;
ALTER FUNCTION public.platform_subscription_plan_set_active(text, boolean) OWNER TO postgres;

REVOKE ALL ON FUNCTION public.platform_subscription_plan_editor_snapshot() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.platform_subscription_plan_upsert(text, text, text, text, numeric, text, integer, integer, integer, integer, integer, integer, boolean, boolean, integer) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.platform_subscription_plan_feature_set(text, text, boolean, integer, jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.platform_subscription_plan_set_active(text, boolean) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION public.platform_subscription_plan_editor_snapshot() TO authenticated;
GRANT EXECUTE ON FUNCTION public.platform_subscription_plan_upsert(text, text, text, text, numeric, text, integer, integer, integer, integer, integer, integer, boolean, boolean, integer) TO authenticated;
GRANT EXECUTE ON FUNCTION public.platform_subscription_plan_feature_set(text, text, boolean, integer, jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION public.platform_subscription_plan_set_active(text, boolean) TO authenticated;

GRANT EXECUTE ON FUNCTION public.platform_subscription_plan_editor_snapshot() TO service_role;
GRANT EXECUTE ON FUNCTION public.platform_subscription_plan_upsert(text, text, text, text, numeric, text, integer, integer, integer, integer, integer, integer, boolean, boolean, integer) TO service_role;
GRANT EXECUTE ON FUNCTION public.platform_subscription_plan_feature_set(text, text, boolean, integer, jsonb) TO service_role;
GRANT EXECUTE ON FUNCTION public.platform_subscription_plan_set_active(text, boolean) TO service_role;

COMMENT ON FUNCTION public.platform_subscription_plan_editor_snapshot()
IS 'Platform-owner-only snapshot for subscription plan editor, including inactive plans and feature mappings.';

COMMENT ON FUNCTION public.platform_subscription_plan_upsert(text, text, text, text, numeric, text, integer, integer, integer, integer, integer, integer, boolean, boolean, integer)
IS 'Platform-owner-only upsert for subscription plan metadata. Does not delete plans.';

COMMENT ON FUNCTION public.platform_subscription_plan_feature_set(text, text, boolean, integer, jsonb)
IS 'Platform-owner-only upsert for subscription plan feature mapping.';

COMMENT ON FUNCTION public.platform_subscription_plan_set_active(text, boolean)
IS 'Platform-owner-only soft activate/deactivate subscription plan.';

COMMIT;
