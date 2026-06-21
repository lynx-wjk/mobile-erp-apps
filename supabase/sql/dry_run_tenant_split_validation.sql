-- supabase/sql/dry_run_tenant_split_validation.sql
-- Dry-run validation script to simulate tenant split and verify data integrity
-- Strictly read-only, no mutations.

-- 1. TENANT ROW COUNT RECONCILIATION
-- Validates that (Sum of Tenant Row Counts) + (Global Row Counts) = Total Row Counts in the database
-- Focuses on high-volume tables: marketplace_orders, marketplace_order_items, marketplace_finance_reports, marketplace_variant_hpp_mappings
WITH table_stats AS (
  SELECT
    'marketplace_orders' as table_name,
    (SELECT COUNT(*) FROM public.marketplace_orders) as total_rows,
    (SELECT COUNT(*) FROM public.marketplace_orders WHERE tenant_id IS NULL) as null_tenant_rows,
    (SELECT SUM(cnt) FROM (
       SELECT COUNT(*) as cnt FROM public.marketplace_orders GROUP BY tenant_id
     ) s) as sum_tenant_rows
  
  UNION ALL
  
  SELECT
    'marketplace_order_items' as table_name,
    (SELECT COUNT(*) FROM public.marketplace_order_items) as total_rows,
    (SELECT COUNT(*) FROM public.marketplace_order_items WHERE tenant_id IS NULL) as null_tenant_rows,
    (SELECT SUM(cnt) FROM (
       SELECT COUNT(*) as cnt FROM public.marketplace_order_items GROUP BY tenant_id
     ) s) as sum_tenant_rows
  
  UNION ALL
  
  SELECT
    'marketplace_finance_reports' as table_name,
    (SELECT COUNT(*) FROM public.marketplace_finance_reports) as total_rows,
    (SELECT COUNT(*) FROM public.marketplace_finance_reports WHERE tenant_id IS NULL) as null_tenant_rows,
    (SELECT SUM(cnt) FROM (
       SELECT COUNT(*) as cnt FROM public.marketplace_finance_reports GROUP BY tenant_id
     ) s) as sum_tenant_rows
     
  UNION ALL
  
  SELECT
    'marketplace_variant_hpp_mappings' as table_name,
    (SELECT COUNT(*) FROM public.marketplace_variant_hpp_mappings) as total_rows,
    (SELECT COUNT(*) FROM public.marketplace_variant_hpp_mappings WHERE tenant_id IS NULL) as null_tenant_rows,
    (SELECT SUM(cnt) FROM (
       SELECT COUNT(*) as cnt FROM public.marketplace_variant_hpp_mappings GROUP BY tenant_id
     ) s) as sum_tenant_rows
)
SELECT 
  table_name,
  total_rows,
  null_tenant_rows,
  coalesce(sum_tenant_rows, 0) as sum_tenant_rows,
  (total_rows = (null_tenant_rows + coalesce(sum_tenant_rows, 0))) as integrity_check_passed
FROM table_stats;


-- 2. CROSS-TENANT DATA LEAKAGE AUDIT (REFERENTIAL CONSISTENCY)
-- Checks if any child records point to a different tenant_id than their parent records
WITH order_item_leakage AS (
  SELECT COUNT(*) as leak_count
  FROM public.marketplace_order_items oi
  JOIN public.marketplace_orders o ON o.marketplace_order_id = oi.marketplace_order_id
  WHERE oi.tenant_id <> o.tenant_id
),
finance_report_leakage AS (
  -- Joins finance report back to orders on order_sn/order_id and accounts
  SELECT COUNT(*) as leak_count
  FROM public.marketplace_finance_reports fr
  JOIN public.marketplace_orders o 
    ON o.order_sn = fr.order_id 
   AND o.marketplace_account_id = fr.marketplace_account_id
  WHERE fr.tenant_id <> o.tenant_id
),
account_leakage AS (
  -- Checks if any account points to a different tenant than its parent table if applicable
  SELECT COUNT(*) as leak_count
  FROM public.marketplace_accounts a
  LEFT JOIN public.app_tenants t ON t.tenant_id = a.tenant_id
  WHERE a.tenant_id IS NOT NULL AND t.tenant_id IS NULL
)
SELECT
  (SELECT leak_count FROM order_item_leakage) as order_item_tenant_mismatches,
  (SELECT leak_count FROM finance_report_leakage) as finance_report_tenant_mismatches,
  (SELECT leak_count FROM account_leakage) as invalid_tenant_accounts,
  CASE 
    WHEN (SELECT leak_count FROM order_item_leakage) + (SELECT leak_count FROM finance_report_leakage) + (SELECT leak_count FROM account_leakage) = 0 
    THEN 'PASSED: Zero tenant leaks found'
    ELSE 'FAILED: Mismatched tenant IDs detected'
  END as cross_tenant_leakage_status;


-- 3. GLOBAL CONFIGURATIONS ACCESSIBILITY AUDIT
-- Verifies that global features, roles, and plans are accessible and populated
SELECT 
  (SELECT COUNT(*) FROM public.feature_catalog) as global_features_count,
  (SELECT COUNT(*) FROM public.roles) as global_roles_count,
  (SELECT COUNT(*) FROM public.subscription_plans) as subscription_plans_count,
  (SELECT COUNT(*) FROM public.subscription_plan_features) as plan_features_count,
  CASE 
    WHEN (SELECT COUNT(*) FROM public.feature_catalog) > 0 
     AND (SELECT COUNT(*) FROM public.roles) > 0 
     AND (SELECT COUNT(*) FROM public.subscription_plans) > 0
    THEN 'PASSED: Global configs are intact'
    ELSE 'FAILED: Empty global config tables'
  END as global_configs_status;
