-- supabase/sql/audit_tenant_isolation_readonly.sql
-- Read-Only Audit of Tenant Isolation in public schema
-- Strictly no mutations (no INSERT/UPDATE/DELETE/DDL)

-- 1. GROUP TABLES BY HAVING tenant_id VS NOT HAVING tenant_id
WITH tables_cols AS (
  SELECT 
    t.table_schema,
    t.table_name,
    COUNT(c.column_name) FILTER (WHERE c.column_name = 'tenant_id') as has_tenant_id
  FROM information_schema.tables t
  JOIN information_schema.columns c 
    ON c.table_schema = t.table_schema 
   AND c.table_name = t.table_name
  WHERE t.table_schema = 'public' 
    AND t.table_type = 'BASE TABLE'
  GROUP BY t.table_schema, t.table_name
)
SELECT 
  CASE WHEN has_tenant_id > 0 THEN 'SCOPED (has tenant_id)' ELSE 'GLOBAL (no tenant_id)' END as isolation_category,
  table_name
FROM tables_cols
ORDER BY isolation_category, table_name;


-- 2. LIST INDEXES SCANNED BY TENANT, DATE, ACCOUNT, ORDER, RESI, AND SKU
SELECT
  tablename as table_name,
  indexname as index_name,
  indexdef as index_definition
FROM pg_indexes
WHERE schemaname = 'public'
  AND (
    indexdef ~* 'tenant_id'
    OR indexdef ~* 'created_at'
    OR indexdef ~* 'order_id'
    OR indexdef ~* 'order_sn'
    OR indexdef ~* 'sku'
    OR indexdef ~* 'resi'
    OR indexdef ~* 'tracking_number'
    OR indexdef ~* 'account_id'
  )
ORDER BY tablename, indexname;


-- 3. ROWS WITH NULL tenant_id IN TENANT-SCOPED TABLES
-- This generates dynamic SQL to check all tables that have tenant_id column
DO $$
DECLARE
  r RECORD;
  v_sql TEXT;
  v_null_count BIGINT;
BEGIN
  RAISE NOTICE '--- AUDITING NULL tenant_id IN TENANT-SCOPED TABLES ---';
  FOR r IN 
    SELECT c.table_name 
    FROM information_schema.columns c
    JOIN information_schema.tables t 
      ON t.table_schema = c.table_schema 
     AND t.table_name = c.table_name
    WHERE c.table_schema = 'public' 
      AND c.column_name = 'tenant_id'
      AND t.table_type = 'BASE TABLE'
    ORDER BY c.table_name
  LOOP
    v_sql := format('SELECT COUNT(*) FROM public.%I WHERE tenant_id IS NULL', r.table_name);
    EXECUTE v_sql INTO v_null_count;
    IF v_null_count > 0 THEN
      RAISE NOTICE 'WARNING: Table public.% has % rows with NULL tenant_id!', r.table_name, v_null_count;
    ELSE
      -- Optional debug output
      -- RAISE NOTICE 'Table public.%: 0 NULL tenant_id rows.', r.table_name;
    END IF;
  END LOOP;
END $$;


-- 4. ROW COUNTS PER TENANT ACROSS ALL SCOPED TABLES
-- This dynamic SQL tallies row counts per tenant code
DO $$
DECLARE
  r RECORD;
  v_sql TEXT;
  v_count BIGINT;
  v_tenant RECORD;
BEGIN
  RAISE NOTICE '--- TALLYS PER TENANT ACROSS TABLES ---';
  FOR v_tenant IN SELECT tenant_id, tenant_code FROM public.app_tenants LOOP
    RAISE NOTICE 'Tenant: % (%)', v_tenant.tenant_code, v_tenant.tenant_id;
    FOR r IN 
      SELECT c.table_name 
      FROM information_schema.columns c
      JOIN information_schema.tables t 
        ON t.table_schema = c.table_schema 
       AND t.table_name = c.table_name
      WHERE c.table_schema = 'public' 
        AND c.column_name = 'tenant_id'
        AND t.table_type = 'BASE TABLE'
      ORDER BY c.table_name
    LOOP
      v_sql := format('SELECT COUNT(*) FROM public.%I WHERE tenant_id = %L', r.table_name, v_tenant.tenant_id);
      EXECUTE v_sql INTO v_count;
      IF v_count > 0 THEN
        RAISE NOTICE '  - Table public.%: % rows', r.table_name, v_count;
      END IF;
    END LOOP;
  END LOOP;
END $$;


-- 5. AUDIT FOREIGN KEY CONSTRAINTS FOR CROSS-TENANT CORRUPTIONS
-- Lists FK constraints where target table has tenant_id but source might not (or vice-versa)
SELECT
    tc.table_name as referencing_table,
    kcu.column_name as referencing_column,
    ccu.table_name as referenced_table,
    ccu.column_name as referenced_column
FROM information_schema.table_constraints AS tc
JOIN information_schema.key_column_usage AS kcu
  ON tc.constraint_name = kcu.constraint_name
  AND tc.table_schema = kcu.table_schema
JOIN information_schema.constraint_column_usage AS ccu
  ON ccu.constraint_name = tc.constraint_name
  AND ccu.table_schema = tc.table_schema
WHERE tc.constraint_type = 'FOREIGN KEY'
  AND tc.table_schema = 'public'
ORDER BY tc.table_name;


-- 6. IDENTIFY ROUTINES (RPCs) ACCEPTING OR REFERENCING tenant_id
SELECT 
  p.proname as function_name,
  pg_get_function_arguments(p.oid) as function_arguments,
  r.rolname as owner,
  l.lanname as language
FROM pg_proc p
JOIN pg_namespace n ON p.pronamespace = n.oid
JOIN pg_roles r ON p.proowner = r.oid
JOIN pg_language l ON p.prolang = l.oid
WHERE n.nspname = 'public'
  AND (
    pg_get_function_arguments(p.oid) ~* 'tenant_id'
    OR p.prosrc ~* 'tenant_id'
  )
ORDER BY p.proname;


-- 7. IDENTIFY PG_CRON JOBS AND THEIR SCOPES
SELECT 
  jobid,
  jobname,
  schedule,
  command,
  active
FROM cron.job
ORDER BY jobid;
