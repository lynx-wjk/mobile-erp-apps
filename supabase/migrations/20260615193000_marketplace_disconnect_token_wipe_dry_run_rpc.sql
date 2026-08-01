BEGIN;

CREATE OR REPLACE FUNCTION public.platform_marketplace_disconnect_token_wipe_dry_run(
  p_tenant_id uuid,
  p_marketplace_account_id uuid,
  p_confirmation text DEFAULT NULL
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
  v_account public.marketplace_accounts%ROWTYPE;
  v_table record;
  v_total_rows bigint;
  v_old_rows bigint;
  v_min_date text;
  v_max_date text;
  v_date_column text;
  v_table_footprint jsonb := '[]'::jsonb;
  v_job_footprint jsonb := '[]'::jsonb;
  v_token_fields_present jsonb;
  v_expected_confirmation text;
  v_summary jsonb;
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
      'message', 'Only active platform_owner users can run marketplace disconnect dry-run.'
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

  v_token_fields_present := jsonb_build_object(
    'app_key', NULLIF(v_account.app_key, '') IS NOT NULL,
    'shop_cipher', NULLIF(v_account.shop_cipher, '') IS NOT NULL,
    'access_token_encrypted', NULLIF(v_account.access_token_encrypted, '') IS NOT NULL,
    'refresh_token_encrypted', NULLIF(v_account.refresh_token_encrypted, '') IS NOT NULL,
    'raw_token_response', v_account.raw_token_response IS NOT NULL AND v_account.raw_token_response <> '{}'::jsonb,
    'access_token_expired_at', v_account.access_token_expired_at IS NOT NULL,
    'refresh_token_expired_at', v_account.refresh_token_expired_at IS NOT NULL,
    'token_last_refreshed_at', v_account.token_last_refreshed_at IS NOT NULL
  );

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
      'select count(*) from public.%I where marketplace_account_id = $1',
      v_table.table_name
    )
    INTO v_total_rows
    USING p_marketplace_account_id;

    IF v_total_rows = 0 THEN
      CONTINUE;
    END IF;

    v_date_column := NULL;

    SELECT c.column_name
    INTO v_date_column
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
         where marketplace_account_id = $1',
        v_date_column,
        v_table.table_name
      )
      INTO v_old_rows, v_min_date, v_max_date
      USING p_marketplace_account_id, v_cutoff_at;
    END IF;

    v_table_footprint := v_table_footprint || jsonb_build_array(
      jsonb_build_object(
        'table_name', v_table.table_name,
        'total_rows', v_total_rows,
        'retention_date_column', v_date_column,
        'old_rows_older_than_90d', v_old_rows,
        'min_retention_date', v_min_date,
        'max_retention_date', v_max_date
      )
    );
  END LOOP;

  IF to_regclass('public.marketplace_order_pull_jobs') IS NOT NULL THEN
    SELECT v_job_footprint || COALESCE(
      jsonb_agg(
        jsonb_build_object(
          'table_name', 'marketplace_order_pull_jobs',
          'status', status,
          'rows', rows_count
        )
        ORDER BY status
      ),
      '[]'::jsonb
    )
    INTO v_job_footprint
    FROM (
      SELECT COALESCE(status, 'unknown') as status, count(*)::bigint as rows_count
      FROM public.marketplace_order_pull_jobs
      WHERE marketplace_account_id = p_marketplace_account_id
      GROUP BY COALESCE(status, 'unknown')
    ) s;
  END IF;

  IF to_regclass('public.finance_sync_jobs') IS NOT NULL THEN
    SELECT v_job_footprint || COALESCE(
      jsonb_agg(
        jsonb_build_object(
          'table_name', 'finance_sync_jobs',
          'status', status,
          'rows', rows_count
        )
        ORDER BY status
      ),
      '[]'::jsonb
    )
    INTO v_job_footprint
    FROM (
      SELECT COALESCE(status, 'unknown') as status, count(*)::bigint as rows_count
      FROM public.finance_sync_jobs
      WHERE marketplace_account_id = p_marketplace_account_id
      GROUP BY COALESCE(status, 'unknown')
    ) s;
  END IF;

  IF to_regclass('public.marketplace_stock_sync_jobs') IS NOT NULL THEN
    SELECT v_job_footprint || COALESCE(
      jsonb_agg(
        jsonb_build_object(
          'table_name', 'marketplace_stock_sync_jobs',
          'status', status,
          'rows', rows_count
        )
        ORDER BY status
      ),
      '[]'::jsonb
    )
    INTO v_job_footprint
    FROM (
      SELECT COALESCE(status, 'unknown') as status, count(*)::bigint as rows_count
      FROM public.marketplace_stock_sync_jobs
      WHERE marketplace_account_id = p_marketplace_account_id
      GROUP BY COALESCE(status, 'unknown')
    ) s;
  END IF;

  SELECT jsonb_build_object(
    'account_found', true,
    'account_status', v_account.status,
    'account_is_active', v_account.is_active,
    'account_is_deleted', v_account.is_deleted,
    'table_entries', COALESCE(jsonb_array_length(v_table_footprint), 0),
    'total_related_rows', COALESCE((
      SELECT SUM((item->>'total_rows')::bigint)
      FROM jsonb_array_elements(v_table_footprint) item
    ), 0),
    'total_old_rows_older_than_90d', COALESCE((
      SELECT SUM((item->>'old_rows_older_than_90d')::bigint)
      FROM jsonb_array_elements(v_table_footprint) item
    ), 0),
    'job_status_entries', COALESCE(jsonb_array_length(v_job_footprint), 0),
    'has_any_token_field', COALESCE((
      SELECT bool_or((value)::boolean)
      FROM jsonb_each_text(v_token_fields_present)
    ), false),
    'no_mutation', true
  )
  INTO v_summary;

  RETURN jsonb_build_object(
    'ok', true,
    'version', 'platform_marketplace_disconnect_token_wipe_dry_run_v1_20260615',
    'generated_at', v_generated_at,
    'summary', v_summary,
    'target', jsonb_build_object(
      'tenant_id', v_account.tenant_id,
      'marketplace_account_id', v_account.marketplace_account_id,
      'marketplace', v_account.marketplace,
      'environment', v_account.environment,
      'status', v_account.status,
      'is_active', v_account.is_active,
      'is_deleted', v_account.is_deleted,
      'shop_name', v_account.shop_name,
      'store_alias', v_account.store_alias,
      'shop_id_masked',
        CASE
          WHEN v_account.shop_id IS NULL OR length(v_account.shop_id) <= 4 THEN v_account.shop_id
          ELSE repeat('*', greatest(length(v_account.shop_id) - 4, 0)) || right(v_account.shop_id, 4)
        END,
      'connected_at', v_account.connected_at,
      'last_connected_at', v_account.last_connected_at,
      'reauthorized_at', v_account.reauthorized_at,
      'revoked_at', v_account.revoked_at
    ),
    'token_fields_present', v_token_fields_present,
    'planned_8c_mutation', jsonb_build_object(
      'requires_exact_confirmation', v_expected_confirmation,
      'provided_confirmation_matches', COALESCE(p_confirmation, '') = v_expected_confirmation,
      'account_update', jsonb_build_object(
        'status', 'revoked',
        'is_active', false,
        'revoked_at', 'now()',
        'last_error', 'Disconnected by platform owner'
      ),
      'token_fields_to_null', jsonb_build_array(
        'access_token_encrypted',
        'refresh_token_encrypted',
        'raw_token_response',
        'access_token_expired_at',
        'refresh_token_expired_at',
        'token_last_refreshed_at'
      ),
      'business_data_delete_in_8c_disconnect', false,
      'retention_purge_requires_separate_explicit_confirmation', true
    ),
    'job_footprint', v_job_footprint,
    'table_footprint', v_table_footprint,
    'safety', jsonb_build_object(
      'dry_run', true,
      'audit_only', true,
      'tokens_redacted', true,
      'no_delete', true,
      'no_update', true,
      'no_token_wipe', true,
      'next_phase', '8C explicit-confirmation disconnect/token wipe execution'
    )
  );
END;
$$;

ALTER FUNCTION public.platform_marketplace_disconnect_token_wipe_dry_run(uuid, uuid, text) OWNER TO postgres;

REVOKE ALL ON FUNCTION public.platform_marketplace_disconnect_token_wipe_dry_run(uuid, uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.platform_marketplace_disconnect_token_wipe_dry_run(uuid, uuid, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.platform_marketplace_disconnect_token_wipe_dry_run(uuid, uuid, text) TO service_role;

COMMENT ON FUNCTION public.platform_marketplace_disconnect_token_wipe_dry_run(uuid, uuid, text)
IS 'Phase 8B dry-run for manual marketplace disconnect/token wipe. Returns target, token field presence, table/job footprint, and exact confirmation string for 8C. Performs no DELETE/UPDATE/token wipe.';

COMMIT;
