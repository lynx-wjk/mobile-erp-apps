BEGIN;

CREATE OR REPLACE FUNCTION public.platform_tenant_subscription_override_revoke(
  p_tenant_id uuid,
  p_override_id uuid DEFAULT NULL,
  p_feature_key text DEFAULT NULL,
  p_reason text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_is_platform_owner boolean;
  v_feature_key text;
  v_revoked_at timestamptz := now();
  v_count integer := 0;
  v_overrides jsonb := '[]'::jsonb;
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
      'message', 'Only active platform_owner users can revoke subscription overrides.'
    );
  END IF;

  IF p_tenant_id IS NULL THEN
    RETURN jsonb_build_object(
      'ok', false,
      'error', 'invalid_tenant',
      'message', 'tenant_id is required.'
    );
  END IF;

  v_feature_key := NULLIF(trim(COALESCE(p_feature_key, '')), '');

  IF p_override_id IS NULL AND v_feature_key IS NULL THEN
    RETURN jsonb_build_object(
      'ok', false,
      'error', 'invalid_override_target',
      'message', 'override_id or feature_key is required.'
    );
  END IF;

  WITH updated AS (
    UPDATE public.tenant_subscription_overrides tso
    SET ends_at = v_revoked_at
    WHERE tso.tenant_id = p_tenant_id
      AND (p_override_id IS NULL OR tso.override_id = p_override_id)
      AND (p_override_id IS NOT NULL OR tso.feature_key = v_feature_key)
      AND (tso.ends_at IS NULL OR tso.ends_at > v_revoked_at)
    RETURNING *
  ),
  event_insert AS (
    INSERT INTO public.tenant_subscription_events (
      tenant_id,
      event_type,
      metadata,
      created_by
    )
    SELECT
      p_tenant_id,
      'override_revoked',
      jsonb_build_object(
        'revoke_reason', NULLIF(trim(COALESCE(p_reason, '')), ''),
        'revoked_at', v_revoked_at,
        'revoked_override', to_jsonb(updated)
      ),
      auth.uid()
    FROM updated
    RETURNING 1
  )
  SELECT
    COUNT(*)::integer,
    COALESCE(jsonb_agg(to_jsonb(updated)), '[]'::jsonb)
  INTO v_count, v_overrides
  FROM updated;

  IF v_count = 0 THEN
    RETURN jsonb_build_object(
      'ok', false,
      'error', 'active_override_not_found',
      'message', 'No active override found for the given tenant and override target.'
    );
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'revoked_count', v_count,
    'revoked_at', v_revoked_at,
    'overrides', v_overrides,
    'message', 'Subscription override revoked.'
  );
END;
$$;

ALTER FUNCTION public.platform_tenant_subscription_override_revoke(uuid, uuid, text, text) OWNER TO postgres;

REVOKE ALL ON FUNCTION public.platform_tenant_subscription_override_revoke(uuid, uuid, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.platform_tenant_subscription_override_revoke(uuid, uuid, text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.platform_tenant_subscription_override_revoke(uuid, uuid, text, text) TO service_role;

COMMENT ON FUNCTION public.platform_tenant_subscription_override_revoke(uuid, uuid, text, text)
IS 'Platform-owner-only safe revoke for tenant subscription overrides. Sets ends_at=now() and writes override_revoked audit events. Does not delete override rows.';

COMMIT;
