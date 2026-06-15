-- Migration: Phase 4B Marketplace RLS Hardening
-- Created At: 2026-06-15T15:00:00
-- This migration secures the public views, locks down global credential tables,
-- and enforces tenant-aware RLS policies on all marketplace tables.

-- -------------------------------------------------------------
-- 1. Recreate Dependent Views with security_invoker = true
-- -------------------------------------------------------------

-- Drop views in cascade order
DROP VIEW IF EXISTS public.marketplace_stock_sync_logs_public CASCADE;
DROP VIEW IF EXISTS public.marketplace_accounts_public CASCADE;

-- Recreate public.marketplace_accounts_public with security_invoker = true
CREATE OR REPLACE VIEW public.marketplace_accounts_public
WITH (security_invoker = true)
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

GRANT SELECT ON TABLE public.marketplace_accounts_public TO authenticated;
GRANT ALL ON TABLE public.marketplace_accounts_public TO service_role;

-- Recreate public.marketplace_stock_sync_logs_public with security_invoker = true
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

GRANT SELECT ON TABLE public.marketplace_stock_sync_logs_public TO authenticated;
GRANT ALL ON TABLE public.marketplace_stock_sync_logs_public TO service_role;


-- -------------------------------------------------------------
-- 2. Drop Existing Role-Only Policies on Core Tables
-- -------------------------------------------------------------

-- marketplace_accounts
DROP POLICY IF EXISTS marketplace_delete_policy ON public.marketplace_accounts;
DROP POLICY IF EXISTS marketplace_insert_policy ON public.marketplace_accounts;
DROP POLICY IF EXISTS marketplace_read_policy ON public.marketplace_accounts;
DROP POLICY IF EXISTS marketplace_update_policy ON public.marketplace_accounts;

-- marketplace_sku_maps
DROP POLICY IF EXISTS marketplace_delete_policy ON public.marketplace_sku_maps;
DROP POLICY IF EXISTS marketplace_insert_policy ON public.marketplace_sku_maps;
DROP POLICY IF EXISTS marketplace_read_policy ON public.marketplace_sku_maps;
DROP POLICY IF EXISTS marketplace_update_policy ON public.marketplace_sku_maps;

-- marketplace_product_snapshots
DROP POLICY IF EXISTS marketplace_delete_policy ON public.marketplace_product_snapshots;
DROP POLICY IF EXISTS marketplace_insert_policy ON public.marketplace_product_snapshots;
DROP POLICY IF EXISTS marketplace_read_policy ON public.marketplace_product_snapshots;
DROP POLICY IF EXISTS marketplace_update_policy ON public.marketplace_product_snapshots;

-- marketplace_variant_snapshots
DROP POLICY IF EXISTS marketplace_variant_snapshots_read_same_tenant ON public.marketplace_variant_snapshots;
DROP POLICY IF EXISTS marketplace_delete_policy ON public.marketplace_variant_snapshots;
DROP POLICY IF EXISTS marketplace_insert_policy ON public.marketplace_variant_snapshots;
DROP POLICY IF EXISTS marketplace_read_policy ON public.marketplace_variant_snapshots;
DROP POLICY IF EXISTS marketplace_update_policy ON public.marketplace_variant_snapshots;

-- marketplace_orders
DROP POLICY IF EXISTS marketplace_orders_select_own_tenant ON public.marketplace_orders;
DROP POLICY IF EXISTS marketplace_delete_policy ON public.marketplace_orders;
DROP POLICY IF EXISTS marketplace_insert_policy ON public.marketplace_orders;
DROP POLICY IF EXISTS marketplace_read_policy ON public.marketplace_orders;
DROP POLICY IF EXISTS marketplace_update_policy ON public.marketplace_orders;

-- marketplace_order_items
DROP POLICY IF EXISTS marketplace_order_items_select_own_tenant ON public.marketplace_order_items;
DROP POLICY IF EXISTS marketplace_delete_policy ON public.marketplace_order_items;
DROP POLICY IF EXISTS marketplace_insert_policy ON public.marketplace_order_items;
DROP POLICY IF EXISTS marketplace_read_policy ON public.marketplace_order_items;
DROP POLICY IF EXISTS marketplace_update_policy ON public.marketplace_order_items;

-- marketplace_finance_reports
DROP POLICY IF EXISTS marketplace_delete_policy ON public.marketplace_finance_reports;
DROP POLICY IF EXISTS marketplace_insert_policy ON public.marketplace_finance_reports;
DROP POLICY IF EXISTS marketplace_read_policy ON public.marketplace_finance_reports;
DROP POLICY IF EXISTS marketplace_update_policy ON public.marketplace_finance_reports;

-- marketplace_finance_items
DROP POLICY IF EXISTS marketplace_delete_policy ON public.marketplace_finance_items;
DROP POLICY IF EXISTS marketplace_insert_policy ON public.marketplace_finance_items;
DROP POLICY IF EXISTS marketplace_read_policy ON public.marketplace_finance_items;
DROP POLICY IF EXISTS marketplace_update_policy ON public.marketplace_finance_items;

-- marketplace_stock_sync_logs
DROP POLICY IF EXISTS marketplace_stock_sync_logs_read_same_tenant ON public.marketplace_stock_sync_logs;
DROP POLICY IF EXISTS marketplace_delete_policy ON public.marketplace_stock_sync_logs;
DROP POLICY IF EXISTS marketplace_insert_policy ON public.marketplace_stock_sync_logs;
DROP POLICY IF EXISTS marketplace_read_policy ON public.marketplace_stock_sync_logs;
DROP POLICY IF EXISTS marketplace_update_policy ON public.marketplace_stock_sync_logs;

-- marketplace_sync_logs
DROP POLICY IF EXISTS marketplace_delete_policy ON public.marketplace_sync_logs;
DROP POLICY IF EXISTS marketplace_insert_policy ON public.marketplace_sync_logs;
DROP POLICY IF EXISTS marketplace_read_policy ON public.marketplace_sync_logs;
DROP POLICY IF EXISTS marketplace_update_policy ON public.marketplace_sync_logs;

-- marketplace_return_refund_cases
DROP POLICY IF EXISTS marketplace_return_refund_cases_select_own_tenant ON public.marketplace_return_refund_cases;

-- marketplace_return_reviews
DROP POLICY IF EXISTS marketplace_return_reviews_select_own_tenant ON public.marketplace_return_reviews;

-- marketplace_return_item_reviews
DROP POLICY IF EXISTS marketplace_return_item_reviews_select_own_tenant ON public.marketplace_return_item_reviews;

-- marketplace_stock_out_reviews
DROP POLICY IF EXISTS marketplace_stock_out_reviews_select_own_tenant ON public.marketplace_stock_out_reviews;

-- marketplace_order_pull_jobs
DROP POLICY IF EXISTS marketplace_order_pull_jobs_insert_tenant ON public.marketplace_order_pull_jobs;
DROP POLICY IF EXISTS marketplace_order_pull_jobs_select_tenant ON public.marketplace_order_pull_jobs;
DROP POLICY IF EXISTS marketplace_order_pull_jobs_update_tenant ON public.marketplace_order_pull_jobs;

-- marketplace_finance_anomalies
DROP POLICY IF EXISTS marketplace_delete_policy ON public.marketplace_finance_anomalies;
DROP POLICY IF EXISTS marketplace_insert_policy ON public.marketplace_finance_anomalies;
DROP POLICY IF EXISTS marketplace_read_policy ON public.marketplace_finance_anomalies;
DROP POLICY IF EXISTS marketplace_update_policy ON public.marketplace_finance_anomalies;

-- marketplace_stock_sync_jobs
DROP POLICY IF EXISTS marketplace_stock_sync_jobs_select_tenant ON public.marketplace_stock_sync_jobs;
DROP POLICY IF EXISTS marketplace_stock_sync_jobs_insert_tenant ON public.marketplace_stock_sync_jobs;
DROP POLICY IF EXISTS marketplace_stock_sync_jobs_update_tenant ON public.marketplace_stock_sync_jobs;

-- marketplace_stock_sync_settings
DROP POLICY IF EXISTS marketplace_stock_sync_settings_read_same_tenant ON public.marketplace_stock_sync_settings;
DROP POLICY IF EXISTS marketplace_stock_sync_settings_select_same_tenant ON public.marketplace_stock_sync_settings;
DROP POLICY IF EXISTS marketplace_stock_sync_settings_update_super_admin ON public.marketplace_stock_sync_settings;
DROP POLICY IF EXISTS marketplace_stock_sync_settings_write_same_tenant ON public.marketplace_stock_sync_settings;
DROP POLICY IF EXISTS marketplace_stock_sync_settings_write_super_admin ON public.marketplace_stock_sync_settings;

-- marketplace_oauth_states
DROP POLICY IF EXISTS marketplace_oauth_states_select_tenant ON public.marketplace_oauth_states;
DROP POLICY IF EXISTS marketplace_oauth_states_insert_tenant ON public.marketplace_oauth_states;
DROP POLICY IF EXISTS marketplace_oauth_states_update_tenant ON public.marketplace_oauth_states;


-- -------------------------------------------------------------
-- 3. Enable RLS and Create Hardened Tenant Policies
-- -------------------------------------------------------------

-- Helper Macro-like structure to run for all tenant-owned tables:
-- 1. ALTER TABLE public.<table_name> ENABLE ROW LEVEL SECURITY;
-- 2. CREATE POLICY <table_name>_tenant_select ON public.<table_name> FOR SELECT TO authenticated USING (tenant_id = public.app_current_tenant_id_or_default() AND public.marketplace_can_read());
-- 3. CREATE POLICY <table_name>_tenant_write ON public.<table_name> FOR ALL TO authenticated USING (tenant_id = public.app_current_tenant_id_or_default() AND public.marketplace_can_write()) WITH CHECK (tenant_id = public.app_current_tenant_id_or_default() AND public.marketplace_can_write());

-- 1. marketplace_accounts
ALTER TABLE public.marketplace_accounts ENABLE ROW LEVEL SECURITY;
CREATE POLICY marketplace_accounts_tenant_select ON public.marketplace_accounts
  FOR SELECT TO authenticated
  USING (tenant_id = public.app_current_tenant_id_or_default() AND public.marketplace_can_read());
CREATE POLICY marketplace_accounts_tenant_write ON public.marketplace_accounts
  FOR ALL TO authenticated
  USING (tenant_id = public.app_current_tenant_id_or_default() AND public.marketplace_can_write())
  WITH CHECK (tenant_id = public.app_current_tenant_id_or_default() AND public.marketplace_can_write());

-- 2. marketplace_sku_maps
ALTER TABLE public.marketplace_sku_maps ENABLE ROW LEVEL SECURITY;
CREATE POLICY marketplace_sku_maps_tenant_select ON public.marketplace_sku_maps
  FOR SELECT TO authenticated
  USING (tenant_id = public.app_current_tenant_id_or_default() AND public.marketplace_can_read());
CREATE POLICY marketplace_sku_maps_tenant_write ON public.marketplace_sku_maps
  FOR ALL TO authenticated
  USING (tenant_id = public.app_current_tenant_id_or_default() AND public.marketplace_can_write())
  WITH CHECK (tenant_id = public.app_current_tenant_id_or_default() AND public.marketplace_can_write());

-- 3. marketplace_product_snapshots
ALTER TABLE public.marketplace_product_snapshots ENABLE ROW LEVEL SECURITY;
CREATE POLICY marketplace_product_snapshots_tenant_select ON public.marketplace_product_snapshots
  FOR SELECT TO authenticated
  USING (tenant_id = public.app_current_tenant_id_or_default() AND public.marketplace_can_read());
CREATE POLICY marketplace_product_snapshots_tenant_write ON public.marketplace_product_snapshots
  FOR ALL TO authenticated
  USING (tenant_id = public.app_current_tenant_id_or_default() AND public.marketplace_can_write())
  WITH CHECK (tenant_id = public.app_current_tenant_id_or_default() AND public.marketplace_can_write());

-- 4. marketplace_variant_snapshots
ALTER TABLE public.marketplace_variant_snapshots ENABLE ROW LEVEL SECURITY;
CREATE POLICY marketplace_variant_snapshots_tenant_select ON public.marketplace_variant_snapshots
  FOR SELECT TO authenticated
  USING (tenant_id = public.app_current_tenant_id_or_default() AND public.marketplace_can_read());
CREATE POLICY marketplace_variant_snapshots_tenant_write ON public.marketplace_variant_snapshots
  FOR ALL TO authenticated
  USING (tenant_id = public.app_current_tenant_id_or_default() AND public.marketplace_can_write())
  WITH CHECK (tenant_id = public.app_current_tenant_id_or_default() AND public.marketplace_can_write());

-- 5. marketplace_orders
ALTER TABLE public.marketplace_orders ENABLE ROW LEVEL SECURITY;
CREATE POLICY marketplace_orders_tenant_select ON public.marketplace_orders
  FOR SELECT TO authenticated
  USING (tenant_id = public.app_current_tenant_id_or_default() AND public.marketplace_can_read());
CREATE POLICY marketplace_orders_tenant_write ON public.marketplace_orders
  FOR ALL TO authenticated
  USING (tenant_id = public.app_current_tenant_id_or_default() AND public.marketplace_can_write())
  WITH CHECK (tenant_id = public.app_current_tenant_id_or_default() AND public.marketplace_can_write());

-- 6. marketplace_order_items
ALTER TABLE public.marketplace_order_items ENABLE ROW LEVEL SECURITY;
CREATE POLICY marketplace_order_items_tenant_select ON public.marketplace_order_items
  FOR SELECT TO authenticated
  USING (tenant_id = public.app_current_tenant_id_or_default() AND public.marketplace_can_read());
CREATE POLICY marketplace_order_items_tenant_write ON public.marketplace_order_items
  FOR ALL TO authenticated
  USING (tenant_id = public.app_current_tenant_id_or_default() AND public.marketplace_can_write())
  WITH CHECK (tenant_id = public.app_current_tenant_id_or_default() AND public.marketplace_can_write());

-- 7. marketplace_finance_reports
ALTER TABLE public.marketplace_finance_reports ENABLE ROW LEVEL SECURITY;
CREATE POLICY marketplace_finance_reports_tenant_select ON public.marketplace_finance_reports
  FOR SELECT TO authenticated
  USING (tenant_id = public.app_current_tenant_id_or_default() AND public.marketplace_can_read());
CREATE POLICY marketplace_finance_reports_tenant_write ON public.marketplace_finance_reports
  FOR ALL TO authenticated
  USING (tenant_id = public.app_current_tenant_id_or_default() AND public.marketplace_can_write())
  WITH CHECK (tenant_id = public.app_current_tenant_id_or_default() AND public.marketplace_can_write());

-- 8. marketplace_finance_items
ALTER TABLE public.marketplace_finance_items ENABLE ROW LEVEL SECURITY;
CREATE POLICY marketplace_finance_items_tenant_select ON public.marketplace_finance_items
  FOR SELECT TO authenticated
  USING (tenant_id = public.app_current_tenant_id_or_default() AND public.marketplace_can_read());
CREATE POLICY marketplace_finance_items_tenant_write ON public.marketplace_finance_items
  FOR ALL TO authenticated
  USING (tenant_id = public.app_current_tenant_id_or_default() AND public.marketplace_can_write())
  WITH CHECK (tenant_id = public.app_current_tenant_id_or_default() AND public.marketplace_can_write());

-- 9. marketplace_stock_sync_logs
ALTER TABLE public.marketplace_stock_sync_logs ENABLE ROW LEVEL SECURITY;
CREATE POLICY marketplace_stock_sync_logs_tenant_select ON public.marketplace_stock_sync_logs
  FOR SELECT TO authenticated
  USING (tenant_id = public.app_current_tenant_id_or_default() AND public.marketplace_can_read());
CREATE POLICY marketplace_stock_sync_logs_tenant_write ON public.marketplace_stock_sync_logs
  FOR ALL TO authenticated
  USING (tenant_id = public.app_current_tenant_id_or_default() AND public.marketplace_can_write())
  WITH CHECK (tenant_id = public.app_current_tenant_id_or_default() AND public.marketplace_can_write());

-- 10. marketplace_sync_logs
ALTER TABLE public.marketplace_sync_logs ENABLE ROW LEVEL SECURITY;
CREATE POLICY marketplace_sync_logs_tenant_select ON public.marketplace_sync_logs
  FOR SELECT TO authenticated
  USING (tenant_id = public.app_current_tenant_id_or_default() AND public.marketplace_can_read());
CREATE POLICY marketplace_sync_logs_tenant_write ON public.marketplace_sync_logs
  FOR ALL TO authenticated
  USING (tenant_id = public.app_current_tenant_id_or_default() AND public.marketplace_can_write())
  WITH CHECK (tenant_id = public.app_current_tenant_id_or_default() AND public.marketplace_can_write());

-- 11. marketplace_return_refund_cases
ALTER TABLE public.marketplace_return_refund_cases ENABLE ROW LEVEL SECURITY;
CREATE POLICY marketplace_return_refund_cases_tenant_select ON public.marketplace_return_refund_cases
  FOR SELECT TO authenticated
  USING (tenant_id = public.app_current_tenant_id_or_default() AND public.marketplace_can_read());
CREATE POLICY marketplace_return_refund_cases_tenant_write ON public.marketplace_return_refund_cases
  FOR ALL TO authenticated
  USING (tenant_id = public.app_current_tenant_id_or_default() AND public.marketplace_can_write())
  WITH CHECK (tenant_id = public.app_current_tenant_id_or_default() AND public.marketplace_can_write());

-- 12. marketplace_return_reviews
ALTER TABLE public.marketplace_return_reviews ENABLE ROW LEVEL SECURITY;
CREATE POLICY marketplace_return_reviews_tenant_select ON public.marketplace_return_reviews
  FOR SELECT TO authenticated
  USING (tenant_id = public.app_current_tenant_id_or_default() AND public.marketplace_can_read());
CREATE POLICY marketplace_return_reviews_tenant_write ON public.marketplace_return_reviews
  FOR ALL TO authenticated
  USING (tenant_id = public.app_current_tenant_id_or_default() AND public.marketplace_can_write())
  WITH CHECK (tenant_id = public.app_current_tenant_id_or_default() AND public.marketplace_can_write());

-- 13. marketplace_return_item_reviews
ALTER TABLE public.marketplace_return_item_reviews ENABLE ROW LEVEL SECURITY;
CREATE POLICY marketplace_return_item_reviews_tenant_select ON public.marketplace_return_item_reviews
  FOR SELECT TO authenticated
  USING (tenant_id = public.app_current_tenant_id_or_default() AND public.marketplace_can_read());
CREATE POLICY marketplace_return_item_reviews_tenant_write ON public.marketplace_return_item_reviews
  FOR ALL TO authenticated
  USING (tenant_id = public.app_current_tenant_id_or_default() AND public.marketplace_can_write())
  WITH CHECK (tenant_id = public.app_current_tenant_id_or_default() AND public.marketplace_can_write());

-- 14. marketplace_stock_out_reviews
ALTER TABLE public.marketplace_stock_out_reviews ENABLE ROW LEVEL SECURITY;
CREATE POLICY marketplace_stock_out_reviews_tenant_select ON public.marketplace_stock_out_reviews
  FOR SELECT TO authenticated
  USING (tenant_id = public.app_current_tenant_id_or_default() AND public.marketplace_can_read());
CREATE POLICY marketplace_stock_out_reviews_tenant_write ON public.marketplace_stock_out_reviews
  FOR ALL TO authenticated
  USING (tenant_id = public.app_current_tenant_id_or_default() AND public.marketplace_can_write())
  WITH CHECK (tenant_id = public.app_current_tenant_id_or_default() AND public.marketplace_can_write());

-- 15. marketplace_order_pull_jobs
ALTER TABLE public.marketplace_order_pull_jobs ENABLE ROW LEVEL SECURITY;
CREATE POLICY marketplace_order_pull_jobs_tenant_select ON public.marketplace_order_pull_jobs
  FOR SELECT TO authenticated
  USING (tenant_id = public.app_current_tenant_id_or_default() AND public.marketplace_can_read());
CREATE POLICY marketplace_order_pull_jobs_tenant_write ON public.marketplace_order_pull_jobs
  FOR ALL TO authenticated
  USING (tenant_id = public.app_current_tenant_id_or_default() AND public.marketplace_can_write())
  WITH CHECK (tenant_id = public.app_current_tenant_id_or_default() AND public.marketplace_can_write());

-- 16. marketplace_finance_anomalies
ALTER TABLE public.marketplace_finance_anomalies ENABLE ROW LEVEL SECURITY;
CREATE POLICY marketplace_finance_anomalies_tenant_select ON public.marketplace_finance_anomalies
  FOR SELECT TO authenticated
  USING (tenant_id = public.app_current_tenant_id_or_default() AND public.marketplace_can_read());
CREATE POLICY marketplace_finance_anomalies_tenant_write ON public.marketplace_finance_anomalies
  FOR ALL TO authenticated
  USING (tenant_id = public.app_current_tenant_id_or_default() AND public.marketplace_can_write())
  WITH CHECK (tenant_id = public.app_current_tenant_id_or_default() AND public.marketplace_can_write());

-- 17. marketplace_stock_sync_jobs
ALTER TABLE public.marketplace_stock_sync_jobs ENABLE ROW LEVEL SECURITY;
CREATE POLICY marketplace_stock_sync_jobs_tenant_select ON public.marketplace_stock_sync_jobs
  FOR SELECT TO authenticated
  USING (tenant_id = public.app_current_tenant_id_or_default() AND public.marketplace_can_read());
CREATE POLICY marketplace_stock_sync_jobs_tenant_write ON public.marketplace_stock_sync_jobs
  FOR ALL TO authenticated
  USING (tenant_id = public.app_current_tenant_id_or_default() AND public.marketplace_can_write())
  WITH CHECK (tenant_id = public.app_current_tenant_id_or_default() AND public.marketplace_can_write());

-- 18. marketplace_stock_sync_settings
ALTER TABLE public.marketplace_stock_sync_settings ENABLE ROW LEVEL SECURITY;
CREATE POLICY marketplace_stock_sync_settings_tenant_select ON public.marketplace_stock_sync_settings
  FOR SELECT TO authenticated
  USING (tenant_id = public.app_current_tenant_id_or_default() AND public.marketplace_can_read());
CREATE POLICY marketplace_stock_sync_settings_tenant_write ON public.marketplace_stock_sync_settings
  FOR ALL TO authenticated
  USING (tenant_id = public.app_current_tenant_id_or_default() AND public.marketplace_can_write())
  WITH CHECK (tenant_id = public.app_current_tenant_id_or_default() AND public.marketplace_can_write());

-- 19. marketplace_oauth_states
ALTER TABLE public.marketplace_oauth_states ENABLE ROW LEVEL SECURITY;
CREATE POLICY marketplace_oauth_states_tenant_select ON public.marketplace_oauth_states
  FOR SELECT TO authenticated
  USING (tenant_id = public.app_current_tenant_id_or_default() AND public.marketplace_can_read());
CREATE POLICY marketplace_oauth_states_tenant_write ON public.marketplace_oauth_states
  FOR ALL TO authenticated
  USING (tenant_id = public.app_current_tenant_id_or_default() AND public.marketplace_can_write())
  WITH CHECK (tenant_id = public.app_current_tenant_id_or_default() AND public.marketplace_can_write());


-- -------------------------------------------------------------
-- 4. Lock Global Tables (No tenant policies -> Deny all except superuser)
-- -------------------------------------------------------------

ALTER TABLE public.marketplace_auto_runner_locks ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.marketplace_cron_edge_config_v24_6_82q ENABLE ROW LEVEL SECURITY;


-- -------------------------------------------------------------
-- 5. Harden Account-Linked Logs (No tenant column directly)
-- -------------------------------------------------------------

ALTER TABLE public.marketplace_auto_pull_request_log_v24_6_82q ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS marketplace_pull_logs_select ON public.marketplace_auto_pull_request_log_v24_6_82q;
CREATE POLICY marketplace_pull_logs_select ON public.marketplace_auto_pull_request_log_v24_6_82q
  FOR SELECT TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM public.marketplace_accounts a
      WHERE a.marketplace_account_id = marketplace_auto_pull_request_log_v24_6_82q.marketplace_account_id
        AND a.tenant_id = public.app_current_tenant_id_or_default()
    )
    AND public.marketplace_can_read()
  );

-- -------------------------------------------------------------
-- 6. Index Safety & Performance Tuning
-- -------------------------------------------------------------

-- Create index for the accounts join to avoid full-table scans
CREATE INDEX IF NOT EXISTS idx_marketplace_auto_pull_req_log_v82q_account_id 
ON public.marketplace_auto_pull_request_log_v24_6_82q(marketplace_account_id);


-- -------------------------------------------------------------
-- 7. SQL Verification Queries
-- -------------------------------------------------------------

-- Verify View Option (reloptions contains security_invoker=true)
-- SELECT reloptions FROM pg_class WHERE relname = 'marketplace_accounts_public';

-- Check RLS enablement
-- SELECT tablename, rowsecurity FROM pg_tables WHERE schemaname = 'public' AND tablename LIKE 'marketplace_%';

-- Verify current policies
-- SELECT tablename, policyname, cmd, qual FROM pg_policies WHERE schemaname = 'public' AND tablename LIKE 'marketplace_%';
