BEGIN;

CREATE OR REPLACE FUNCTION public.platform_marketplace_disconnect_cleanup_audit(
  p_tenant_id uuid DEFAULT NULL,
  p_marketplace_account_id uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_is_platform_owner boolean;
  v_generated_at timestamptz := now();
  v_cutoff_at timestamptz := now() - interval '90 days';
  v_accounts jsonb := '[]'::jsonb;
  v_table_footprint jsonb := '[]'::jsonb;
  v_summary jsonb := '{}'::jsonb;
  v_account record;
  v_table record;
  v_total_rows bigint;
  v_old_rows bigint;
  v_min_date text;
  v_max_date text;
  v_date_column text;
  v_date_type text;
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
      'message', 'Only active platform_owner users can run marketplace disconnect cleanup audit.'
    );
  END IF;

  SELECT COALESCE(
    jsonb_agg(
      jsonb_build_object(
        'tenant_id', ma.tenant_id,
        'marketplace_account_id', ma.marketplace_account_id,
        'marketplace', ma.marketplace,
        'environment', ma.environment,
        'status', ma.status,
        'is_active', ma.is_active,
        'is_deleted', ma.is_deleted,
        'shop_name', ma.shop_name,
        'store_alias', ma.store_alias,
        'shop_id_masked',
          CASE
            WHEN ma.shop_id IS NULL OR length(ma.shop_id) <= 4 THEN ma.shop_id
            ELSE repeat('*', greatest(length(ma.shop_id) - 4, 0)) || right(ma.shop_id, 4)
          END,
        'connected_at', ma.connected_at,
        'last_connected_at', ma.last_connected_at,
        'reauthorized_at', ma.reauthorized_at,
        'revoked_at', ma.revoked_at,
        'access_token_expired_at', ma.access_token_expired_at,
        'refresh_token_expired_at', ma.refresh_token_expired_at,
        'token_last_refreshed_at', ma.token_last_refreshed_at,
        'token_fields_present', jsonb_build_object(
          'app_key', NULLIF(ma.app_key, '') IS NOT NULL,
          'shop_cipher', NULLIF(ma.shop_cipher, '') IS NOT NULL,
          'access_token_encrypted', NULLIF(ma.access_token_encrypted, '') IS NOT NULL,
          'refresh_token_encrypted', NULLIF(ma.refresh_token_encrypted, '') IS NOT NULL,
          'raw_token_response', ma.raw_token_response IS NOT NULL AND ma.raw_token_response <> '{}'::jsonb
        ),
        'future_disconnect_preview', jsonb_build_object(
          'will_soft_revoke_account', true,
          'will_wipe_token_fields', jsonb_build_array(
            'access_token_encrypted',
            'refresh_token_encrypted',
            'raw_token_response',
            'access_token_expired_at',
            'refresh_token_expired_at',
            'token_last_refreshed_at'
          ),
          'will_not_delete_account_row', true,
          'will_not_delete_business_data_in_disconnect_step', true
        )
      )
      ORDER BY ma.tenant_id, ma.marketplace, ma.shop_name, ma.store_alias
    ),
    '[]'::jsonb
  )
  INTO v_accounts
  FROM public.marketplace_accounts ma
  WHERE (p_tenant_id IS NULL OR ma.tenant_id = p_tenant_id)
    AND (p_marketplace_account_id IS NULL OR ma.marketplace_account_id = p_marketplace_account_id);

  FOR v_account IN
    SELECT ma.marketplace_account_id, ma.tenant_id, ma.marketplace
    FROM public.marketplace_accounts ma
    WHERE (p_tenant_id IS NULL OR ma.tenant_id = p_tenant_id)
      AND (p_marketplace_account_id IS NULL OR ma.marketplace_account_id = p_marketplace_account_id)
    ORDER BY ma.tenant_id, ma.marketplace, ma.marketplace_account_id
  LOOP
    FOR v_table IN
      SELECT DISTINCT c.table_name
      FROM information_schema.columns c
      JOIN information_schema.tables t
        ON t.table_schema = c.table_schema
       AND t.table_name = c.table_name
      WHERE c.table_schema = 'public'
        AND c.column_name = 'marketplace_account_id'
        AND t.table_type = 'BASE TABLE'
      ORDER BY c.table_name
    LOOP
      EXECUTE format(
        'select count(*) from public.%I where marketplace_account_id::text = $1',
        v_table.table_name
      )
      INTO v_total_rows
      USING v_account.marketplace_account_id::text;

      IF v_total_rows = 0 THEN
        CONTINUE;
      END IF;

      v_date_column := NULL;
      v_date_type := NULL;

      SELECT c.column_name, c.data_type
      INTO v_date_column, v_date_type
      FROM information_schema.columns c
      WHERE c.table_schema = 'public'
        AND c.table_name = v_table.table_name
        AND c.column_name IN (
          'order_created_at',
          'transaction_time',
          'settlement_date',
          'period_start',
          'requested_at',
          'pulled_at',
          'created_at',
          'updated_at'
        )
        AND c.data_type IN (
          'timestamp with time zone',
          'timestamp without time zone',
          'date'
        )
      ORDER BY CASE c.column_name
        WHEN 'order_created_at' THEN 1
        WHEN 'transaction_time' THEN 2
        WHEN 'settlement_date' THEN 3
        WHEN 'period_start' THEN 4
        WHEN 'requested_at' THEN 5
        WHEN 'pulled_at' THEN 6
        WHEN 'created_at' THEN 7
        WHEN 'updated_at' THEN 8
        ELSE 99
      END
      LIMIT 1;

      v_old_rows := 0;
      v_min_date := NULL;
      v_max_date := NULL;

      IF v_date_column IS NOT NULL THEN
        EXECUTE format(
          'select
             count(*) filter (where (%1$I)::timestamptz < $2),
             min((%1$I)::timestamptz)::text,
             max((%1$I)::timestamptz)::text
           from public.%2$I
           where marketplace_account_id::text = $1',
          v_date_column,
          v_table.table_name
        )
        INTO v_old_rows, v_min_date, v_max_date
        USING v_account.marketplace_account_id::text, v_cutoff_at;
      END IF;

      v_table_footprint := v_table_footprint || jsonb_build_array(
        jsonb_build_object(
          'tenant_id', v_account.tenant_id,
          'marketplace_account_id', v_account.marketplace_account_id,
          'marketplace', v_account.marketplace,
          'table_name', v_table.table_name,
          'total_rows', v_total_rows,
          'retention_date_column', v_date_column,
          'old_rows_older_than_90d', v_old_rows,
          'min_retention_date', v_min_date,
          'max_retention_date', v_max_date
        )
      );
    END LOOP;
  END LOOP;

  SELECT jsonb_build_object(
    'account_count', COALESCE(jsonb_array_length(v_accounts), 0),
    'footprint_table_entries', COALESCE(jsonb_array_length(v_table_footprint), 0),
    'total_rows_in_footprint', COALESCE((
      SELECT SUM((item->>'total_rows')::bigint)
      FROM jsonb_array_elements(v_table_footprint) item
    ), 0),
    'total_old_rows_older_than_90d', COALESCE((
      SELECT SUM((item->>'old_rows_older_than_90d')::bigint)
      FROM jsonb_array_elements(v_table_footprint) item
    ), 0),
    'cutoff_at', v_cutoff_at,
    'no_mutation', true
  )
  INTO v_summary;

  RETURN jsonb_build_object(
    'ok', true,
    'version', 'platform_marketplace_disconnect_cleanup_audit_v1_20260615',
    'generated_at', v_generated_at,
    'filters', jsonb_build_object(
      'tenant_id', p_tenant_id,
      'marketplace_account_id', p_marketplace_account_id
    ),
    'summary', v_summary,
    'accounts', v_accounts,
    'table_footprint', v_table_footprint,
    'safety', jsonb_build_object(
      'audit_only', true,
      'tokens_redacted', true,
      'no_delete', true,
      'no_update', true,
      'no_token_wipe', true,
      'next_phase', '8B manual disconnect/token wipe dry-run'
    )
  );
END;
$$;

ALTER FUNCTION public.platform_marketplace_disconnect_cleanup_audit(uuid, uuid) OWNER TO postgres;

REVOKE ALL ON FUNCTION public.platform_marketplace_disconnect_cleanup_audit(uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.platform_marketplace_disconnect_cleanup_audit(uuid, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.platform_marketplace_disconnect_cleanup_audit(uuid, uuid) TO service_role;

COMMENT ON FUNCTION public.platform_marketplace_disconnect_cleanup_audit(uuid, uuid)
IS 'Phase 8A audit-only marketplace disconnect/token wipe/data purge preview. Returns redacted account/token presence and per-table footprint. Performs no DELETE/UPDATE/token wipe.';

COMMIT;
