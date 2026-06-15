BEGIN;

CREATE OR REPLACE FUNCTION public.platform_marketplace_disconnect_token_wipe_execute(
  p_tenant_id uuid,
  p_marketplace_account_id uuid,
  p_confirmation text,
  p_execute boolean DEFAULT false,
  p_reason text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_is_platform_owner boolean;
  v_actor_id uuid := auth.uid();
  v_now timestamptz := now();
  v_account public.marketplace_accounts%ROWTYPE;
  v_expected_confirmation text;
  v_confirmation_matches boolean := false;
  v_before jsonb;
  v_after jsonb;
  v_updated_count integer := 0;
  v_log_inserted boolean := false;
BEGIN
  SELECT EXISTS (
    SELECT 1
    FROM public.users u
    WHERE u.user_id = v_actor_id
      AND u.role_id = 'platform_owner'
      AND COALESCE(u.status, 'active') = 'active'
  )
  INTO v_is_platform_owner;

  IF NOT v_is_platform_owner THEN
    RETURN jsonb_build_object(
      'ok', false,
      'error', 'forbidden',
      'message', 'Only active platform_owner users can execute marketplace disconnect/token wipe.'
    );
  END IF;

  IF p_tenant_id IS NULL OR p_marketplace_account_id IS NULL THEN
    RETURN jsonb_build_object(
      'ok', false,
      'error', 'invalid_target',
      'message', 'tenant_id and marketplace_account_id are required.'
    );
  END IF;

  SELECT *
  INTO v_account
  FROM public.marketplace_accounts ma
  WHERE ma.tenant_id = p_tenant_id
    AND ma.marketplace_account_id = p_marketplace_account_id
  LIMIT 1;

  IF NOT FOUND THEN
    RETURN jsonb_build_object(
      'ok', false,
      'error', 'account_not_found',
      'message', 'Marketplace account not found for the given tenant_id and marketplace_account_id.'
    );
  END IF;

  v_expected_confirmation :=
    'DRY-RUN DISCONNECT ' ||
    v_account.marketplace || ' ' ||
    v_account.marketplace_account_id::text;

  v_confirmation_matches := COALESCE(p_confirmation, '') = v_expected_confirmation;

  v_before := jsonb_build_object(
    'tenant_id', v_account.tenant_id,
    'marketplace_account_id', v_account.marketplace_account_id,
    'marketplace', v_account.marketplace,
    'environment', v_account.environment,
    'status', v_account.status,
    'is_active', v_account.is_active,
    'is_deleted', v_account.is_deleted,
    'shop_name', v_account.shop_name,
    'store_alias', v_account.store_alias,
    'revoked_at', v_account.revoked_at,
    'token_fields_present', jsonb_build_object(
      'access_token_encrypted', NULLIF(v_account.access_token_encrypted, '') IS NOT NULL,
      'refresh_token_encrypted', NULLIF(v_account.refresh_token_encrypted, '') IS NOT NULL,
      'raw_token_response', v_account.raw_token_response IS NOT NULL AND v_account.raw_token_response <> '{}'::jsonb,
      'access_token_expired_at', v_account.access_token_expired_at IS NOT NULL,
      'refresh_token_expired_at', v_account.refresh_token_expired_at IS NOT NULL,
      'token_last_refreshed_at', v_account.token_last_refreshed_at IS NOT NULL
    )
  );

  IF NOT v_confirmation_matches THEN
    RETURN jsonb_build_object(
      'ok', false,
      'error', 'confirmation_mismatch',
      'message', 'Exact confirmation string is required. No mutation performed.',
      'expected_confirmation', v_expected_confirmation,
      'provided_confirmation_matches', false,
      'execute_requested', p_execute,
      'before', v_before,
      'safety', jsonb_build_object(
        'no_delete', true,
        'no_update', true,
        'no_token_wipe', true,
        'tokens_redacted', true
      )
    );
  END IF;

  IF p_execute IS DISTINCT FROM true THEN
    RETURN jsonb_build_object(
      'ok', false,
      'error', 'execute_flag_required',
      'message', 'Confirmation matches, but p_execute=true is required. No mutation performed.',
      'expected_confirmation', v_expected_confirmation,
      'provided_confirmation_matches', true,
      'execute_requested', p_execute,
      'before', v_before,
      'safety', jsonb_build_object(
        'no_delete', true,
        'no_update', true,
        'no_token_wipe', true,
        'tokens_redacted', true
      )
    );
  END IF;

  UPDATE public.marketplace_accounts ma
  SET
    status = 'revoked',
    is_active = false,
    revoked_at = v_now,
    access_token_encrypted = NULL,
    refresh_token_encrypted = NULL,
    raw_token_response = NULL,
    access_token_expired_at = NULL,
    refresh_token_expired_at = NULL,
    token_last_refreshed_at = NULL,
    stock_sync_enabled = false,
    last_error = trim(
      both ' ' from concat(
        'Disconnected by platform owner',
        CASE
          WHEN NULLIF(trim(COALESCE(p_reason, '')), '') IS NULL THEN ''
          ELSE ': ' || trim(p_reason)
        END
      )
    ),
    updated_at = v_now
  WHERE ma.tenant_id = p_tenant_id
    AND ma.marketplace_account_id = p_marketplace_account_id;

  GET DIAGNOSTICS v_updated_count = ROW_COUNT;

  SELECT jsonb_build_object(
    'tenant_id', ma.tenant_id,
    'marketplace_account_id', ma.marketplace_account_id,
    'marketplace', ma.marketplace,
    'environment', ma.environment,
    'status', ma.status,
    'is_active', ma.is_active,
    'is_deleted', ma.is_deleted,
    'shop_name', ma.shop_name,
    'store_alias', ma.store_alias,
    'revoked_at', ma.revoked_at,
    'stock_sync_enabled', ma.stock_sync_enabled,
    'token_fields_present', jsonb_build_object(
      'access_token_encrypted', NULLIF(ma.access_token_encrypted, '') IS NOT NULL,
      'refresh_token_encrypted', NULLIF(ma.refresh_token_encrypted, '') IS NOT NULL,
      'raw_token_response', ma.raw_token_response IS NOT NULL AND ma.raw_token_response <> '{}'::jsonb,
      'access_token_expired_at', ma.access_token_expired_at IS NOT NULL,
      'refresh_token_expired_at', ma.refresh_token_expired_at IS NOT NULL,
      'token_last_refreshed_at', ma.token_last_refreshed_at IS NOT NULL
    )
  )
  INTO v_after
  FROM public.marketplace_accounts ma
  WHERE ma.tenant_id = p_tenant_id
    AND ma.marketplace_account_id = p_marketplace_account_id;

  IF to_regclass('public.marketplace_sync_logs') IS NOT NULL THEN
    INSERT INTO public.marketplace_sync_logs (
      sync_log_id,
      tenant_id,
      marketplace_account_id,
      marketplace,
      action,
      status,
      message,
      request_payload,
      response_payload,
      created_at
    )
    VALUES (
      gen_random_uuid(),
      p_tenant_id,
      p_marketplace_account_id,
      v_account.marketplace,
      'platform_disconnect_token_wipe',
      'done',
      'Marketplace account disconnected and token fields wiped by platform owner.',
      jsonb_build_object(
        'confirmation_used', true,
        'execute_requested', true,
        'reason', NULLIF(trim(COALESCE(p_reason, '')), '')
      ),
      jsonb_build_object(
        'before', v_before,
        'after', v_after,
        'tokens_redacted', true
      ),
      v_now
    );

    v_log_inserted := true;
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'version', 'platform_marketplace_disconnect_token_wipe_execute_v1_20260615',
    'message', 'Marketplace account disconnected and token fields wiped.',
    'updated_count', v_updated_count,
    'log_inserted', v_log_inserted,
    'expected_confirmation', v_expected_confirmation,
    'provided_confirmation_matches', true,
    'executed_at', v_now,
    'before', v_before,
    'after', v_after,
    'safety', jsonb_build_object(
      'no_delete', true,
      'business_data_deleted', false,
      'tokens_redacted', true,
      'token_wipe_executed', true,
      'retention_purge_executed', false
    )
  );
END;
$$;

ALTER FUNCTION public.platform_marketplace_disconnect_token_wipe_execute(uuid, uuid, text, boolean, text) OWNER TO postgres;

REVOKE ALL ON FUNCTION public.platform_marketplace_disconnect_token_wipe_execute(uuid, uuid, text, boolean, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.platform_marketplace_disconnect_token_wipe_execute(uuid, uuid, text, boolean, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.platform_marketplace_disconnect_token_wipe_execute(uuid, uuid, text, boolean, text) TO service_role;

COMMENT ON FUNCTION public.platform_marketplace_disconnect_token_wipe_execute(uuid, uuid, text, boolean, text)
IS 'Phase 8C guarded execution for manual marketplace disconnect/token wipe. Requires exact confirmation and p_execute=true. Wipes token fields and revokes account without deleting business data.';

COMMIT;
