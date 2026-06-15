-- Emergency Rollback Script: Phase 4B Marketplace RLS Hardening
-- Created At: 2026-06-15T15:00:00
-- This script disables Row Level Security on all affected marketplace tables
-- and restores the public views to their previous defaults (bypassing RLS).
-- WARNING: This is for emergency rollback only!

-- -------------------------------------------------------------
-- 1. Disable RLS on core tables
-- -------------------------------------------------------------

ALTER TABLE public.marketplace_accounts DISABLE ROW LEVEL SECURITY;
ALTER TABLE public.marketplace_sku_maps DISABLE ROW LEVEL SECURITY;
ALTER TABLE public.marketplace_product_snapshots DISABLE ROW LEVEL SECURITY;
ALTER TABLE public.marketplace_variant_snapshots DISABLE ROW LEVEL SECURITY;
ALTER TABLE public.marketplace_orders DISABLE ROW LEVEL SECURITY;
ALTER TABLE public.marketplace_order_items DISABLE ROW LEVEL SECURITY;
ALTER TABLE public.marketplace_finance_reports DISABLE ROW LEVEL SECURITY;
ALTER TABLE public.marketplace_finance_items DISABLE ROW LEVEL SECURITY;
ALTER TABLE public.marketplace_stock_sync_logs DISABLE ROW LEVEL SECURITY;
ALTER TABLE public.marketplace_sync_logs DISABLE ROW LEVEL SECURITY;
ALTER TABLE public.marketplace_return_refund_cases DISABLE ROW LEVEL SECURITY;
ALTER TABLE public.marketplace_return_reviews DISABLE ROW LEVEL SECURITY;
ALTER TABLE public.marketplace_return_item_reviews DISABLE ROW LEVEL SECURITY;
ALTER TABLE public.marketplace_stock_out_reviews DISABLE ROW LEVEL SECURITY;
ALTER TABLE public.marketplace_order_pull_jobs DISABLE ROW LEVEL SECURITY;
ALTER TABLE public.marketplace_finance_anomalies DISABLE ROW LEVEL SECURITY;
ALTER TABLE public.marketplace_stock_sync_jobs DISABLE ROW LEVEL SECURITY;
ALTER TABLE public.marketplace_stock_sync_settings DISABLE ROW LEVEL SECURITY;
ALTER TABLE public.marketplace_oauth_states DISABLE ROW LEVEL SECURITY;
ALTER TABLE public.marketplace_auto_runner_locks DISABLE ROW LEVEL SECURITY;
ALTER TABLE public.marketplace_cron_edge_config_v24_6_82q DISABLE ROW LEVEL SECURITY;
ALTER TABLE public.marketplace_auto_pull_request_log_v24_6_82q DISABLE ROW LEVEL SECURITY;

-- -------------------------------------------------------------
-- 2. Drop policies to clean up
-- -------------------------------------------------------------

DROP POLICY IF EXISTS marketplace_accounts_tenant_select ON public.marketplace_accounts;
DROP POLICY IF EXISTS marketplace_accounts_tenant_write ON public.marketplace_accounts;

DROP POLICY IF EXISTS marketplace_sku_maps_tenant_select ON public.marketplace_sku_maps;
DROP POLICY IF EXISTS marketplace_sku_maps_tenant_write ON public.marketplace_sku_maps;

DROP POLICY IF EXISTS marketplace_product_snapshots_tenant_select ON public.marketplace_product_snapshots;
DROP POLICY IF EXISTS marketplace_product_snapshots_tenant_write ON public.marketplace_product_snapshots;

DROP POLICY IF EXISTS marketplace_variant_snapshots_tenant_select ON public.marketplace_variant_snapshots;
DROP POLICY IF EXISTS marketplace_variant_snapshots_tenant_write ON public.marketplace_variant_snapshots;

DROP POLICY IF EXISTS marketplace_orders_tenant_select ON public.marketplace_orders;
DROP POLICY IF EXISTS marketplace_orders_tenant_write ON public.marketplace_orders;

DROP POLICY IF EXISTS marketplace_order_items_tenant_select ON public.marketplace_order_items;
DROP POLICY IF EXISTS marketplace_order_items_tenant_write ON public.marketplace_order_items;

DROP POLICY IF EXISTS marketplace_finance_reports_tenant_select ON public.marketplace_finance_reports;
DROP POLICY IF EXISTS marketplace_finance_reports_tenant_write ON public.marketplace_finance_reports;

DROP POLICY IF EXISTS marketplace_finance_items_tenant_select ON public.marketplace_finance_items;
DROP POLICY IF EXISTS marketplace_finance_items_tenant_write ON public.marketplace_finance_items;

DROP POLICY IF EXISTS marketplace_stock_sync_logs_tenant_select ON public.marketplace_stock_sync_logs;
DROP POLICY IF EXISTS marketplace_stock_sync_logs_tenant_write ON public.marketplace_stock_sync_logs;

DROP POLICY IF EXISTS marketplace_sync_logs_tenant_select ON public.marketplace_sync_logs;
DROP POLICY IF EXISTS marketplace_sync_logs_tenant_write ON public.marketplace_sync_logs;

DROP POLICY IF EXISTS marketplace_return_refund_cases_tenant_select ON public.marketplace_return_refund_cases;
DROP POLICY IF EXISTS marketplace_return_refund_cases_tenant_write ON public.marketplace_return_refund_cases;

DROP POLICY IF EXISTS marketplace_return_reviews_tenant_select ON public.marketplace_return_reviews;
DROP POLICY IF EXISTS marketplace_return_reviews_tenant_write ON public.marketplace_return_reviews;

DROP POLICY IF EXISTS marketplace_return_item_reviews_tenant_select ON public.marketplace_return_item_reviews;
DROP POLICY IF EXISTS marketplace_return_item_reviews_tenant_write ON public.marketplace_return_item_reviews;

DROP POLICY IF EXISTS marketplace_stock_out_reviews_tenant_select ON public.marketplace_stock_out_reviews;
DROP POLICY IF EXISTS marketplace_stock_out_reviews_tenant_write ON public.marketplace_stock_out_reviews;

DROP POLICY IF EXISTS marketplace_order_pull_jobs_tenant_select ON public.marketplace_order_pull_jobs;
DROP POLICY IF EXISTS marketplace_order_pull_jobs_tenant_write ON public.marketplace_order_pull_jobs;

DROP POLICY IF EXISTS marketplace_finance_anomalies_tenant_select ON public.marketplace_finance_anomalies;
DROP POLICY IF EXISTS marketplace_finance_anomalies_tenant_write ON public.marketplace_finance_anomalies;

DROP POLICY IF EXISTS marketplace_stock_sync_jobs_tenant_select ON public.marketplace_stock_sync_jobs;
DROP POLICY IF EXISTS marketplace_stock_sync_jobs_tenant_write ON public.marketplace_stock_sync_jobs;

DROP POLICY IF EXISTS marketplace_stock_sync_settings_tenant_select ON public.marketplace_stock_sync_settings;
DROP POLICY IF EXISTS marketplace_stock_sync_settings_tenant_write ON public.marketplace_stock_sync_settings;

DROP POLICY IF EXISTS marketplace_oauth_states_tenant_select ON public.marketplace_oauth_states;
DROP POLICY IF EXISTS marketplace_oauth_states_tenant_write ON public.marketplace_oauth_states;

DROP POLICY IF EXISTS marketplace_pull_logs_select ON public.marketplace_auto_pull_request_log_v24_6_82q;


-- -------------------------------------------------------------
-- 3. Restore Public Views without security_invoker = true
-- -------------------------------------------------------------

DROP VIEW IF EXISTS public.marketplace_stock_sync_logs_public CASCADE;
DROP VIEW IF EXISTS public.marketplace_accounts_public CASCADE;

-- Recreate marketplace_accounts_public without security_invoker (definer default behavior)
CREATE OR REPLACE VIEW public.marketplace_accounts_public
AS
 SELECT marketplace_account_id,
    tenant_id,
    marketplace,
    COALESCE(NULLIF(store_alias, ''::text), shop_name, marketplace) AS store_alias,
    shop_name,
    shop_region,
    status,
    CASE
        WHEN ((shop_id IS NULL) OR (length(shop_id) <= 8)) THEN shop_id
        ELSE ((left(shop_id, 4) || '...'::text) || right(shop_id, 4))
    END AS shop_id_masked,
    CASE
        WHEN ((shop_cipher IS NULL) OR (length(shop_cipher) <= 12)) THEN shop_cipher
        ELSE ((left(shop_cipher, 6) || '...'::text) || right(shop_cipher, 6))
    END AS shop_cipher_masked,
    access_token_expired_at,
    refresh_token_expired_at,
    last_error,
    connected_at,
    reauthorized_at,
    revoked_at,
    created_at,
    updated_at,
    COALESCE(NULLIF(environment, ''::text), 'production'::text) AS environment
   FROM public.marketplace_accounts;

ALTER VIEW public.marketplace_accounts_public OWNER TO postgres;

GRANT ALL ON TABLE public.marketplace_accounts_public TO authenticated;
GRANT ALL ON TABLE public.marketplace_accounts_public TO service_role;

-- Recreate marketplace_stock_sync_logs_public WITH security_invoker=true (it originally had it)
CREATE OR REPLACE VIEW public.marketplace_stock_sync_logs_public 
WITH (security_invoker = true) 
AS
 SELECT l.marketplace_stock_sync_log_id,
    l.tenant_id,
    l.marketplace_account_id,
    COALESCE(a.marketplace, m.marketplace, l.marketplace, '-'::text) AS marketplace,
    COALESCE(a.store_alias, m.account_store_alias, '-'::text) AS account_store_alias,
    COALESCE(a.shop_name, m.account_shop_name, '-'::text) AS account_shop_name,
    l.marketplace_sku_map_id,
    COALESCE(l.product_id, m.product_id) AS product_id,
    COALESCE(NULLIF(l.local_sku, ''::text), m.local_sku, '-'::text) AS local_sku,
    COALESCE(m.local_product_name, '-'::text) AS local_product_name,
    COALESCE(m.local_stock, l.requested_stock, (0)::numeric) AS local_stock,
    COALESCE(NULLIF(l.marketplace_product_id, ''::text), m.marketplace_product_id) AS marketplace_product_id,
    COALESCE(NULLIF(l.marketplace_sku_id, ''::text), m.marketplace_sku_id) AS marketplace_sku_id,
    m.marketplace_seller_sku,
    COALESCE(m.marketplace_product_name, '-'::text) AS marketplace_product_name,
    m.marketplace_variation_name,
    COALESCE(l.requested_stock, m.local_stock, (0)::numeric) AS requested_stock,
    l.sync_status,
        CASE l.sync_status
            WHEN 'queued'::text THEN 'Queued'::text
            WHEN 'processing'::text THEN 'Processing'::text
            WHEN 'success'::text THEN 'Success'::text
            WHEN 'dry_run_success'::text THEN 'Dry-run OK'::text
            WHEN 'waiting_marketplace_ids'::text THEN 'Waiting ID'::text
            WHEN 'auth_required'::text THEN 'Auth Required'::text
            WHEN 'skipped'::text THEN 'Skipped'::text
            WHEN 'failed'::text THEN 'Failed'::text
            WHEN 'failed_retryable'::text THEN 'Failed'::text
            WHEN 'failed_final'::text THEN 'Failed Final'::text
            ELSE initcap(replace(COALESCE(l.sync_status, '-'::text), '_'::text, ' '::text))
        END AS status_label,
    COALESCE(l.attempt_count, 0) AS attempt_count,
    l.error_message,
    l.worker_message,
    l.worker_name,
    COALESCE(l.is_dry_run, false) AS is_dry_run,
    l.request_payload,
    l.response_payload,
    l.created_at,
    l.started_at,
    l.finished_at,
    l.updated_at,
        CASE
            WHEN (l.sync_status = ANY (ARRAY['failed'::text, 'failed_retryable'::text, 'failed_final'::text, 'waiting_marketplace_ids'::text, 'skipped'::text])) THEN true
            ELSE false
        END AS can_retry,
        CASE
            WHEN (l.sync_status = ANY (ARRAY['queued'::text, 'processing'::text])) THEN false
            ELSE true
        END AS can_delete
   FROM ((public.marketplace_stock_sync_logs l
     LEFT JOIN public.marketplace_sku_maps_public m ON ((m.marketplace_sku_map_id = l.marketplace_sku_map_id)))
     LEFT JOIN public.marketplace_accounts_public a ON ((a.marketplace_account_id = l.marketplace_account_id)))
  WHERE (EXISTS ( SELECT 1
           FROM public.users u
          WHERE ((u.user_id = auth.uid()) AND (u.tenant_id = l.tenant_id) AND (u.status = 'active'::text))));

ALTER VIEW public.marketplace_stock_sync_logs_public OWNER TO postgres;

GRANT ALL ON TABLE public.marketplace_stock_sync_logs_public TO authenticated;
GRANT ALL ON TABLE public.marketplace_stock_sync_logs_public TO service_role;
