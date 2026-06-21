-- ==============================================================================
-- URGENT STABILITY HOTFIX: SELECT-ONLY DUPLICATE FINANCE AUDIT
-- ==============================================================================
-- This script safely identifies potential duplicate data entries across 
-- finance tables without executing any DELETE, DROP, or TRUNCATE operations.
-- It strictly adheres to SELECT-only principles.

-- 1. Identify duplicates in marketplace_finance_reports
-- Groups by tenant, marketplace account, order_id, and statement_id to find duplicates.
WITH duplicated_finance AS (
    SELECT 
        tenant_id,
        marketplace_account_id,
        order_id,
        statement_id,
        COUNT(*) as occurrence_count
    FROM public.marketplace_finance_reports
    GROUP BY 
        tenant_id,
        marketplace_account_id,
        order_id,
        statement_id
    HAVING COUNT(*) > 1
)
SELECT * FROM duplicated_finance;

-- 2. Identify duplicates in marketplace_orders
-- Groups by tenant, marketplace account, and order_sn to find duplicates.
WITH duplicated_orders AS (
    SELECT
        tenant_id,
        marketplace_account_id,
        coalesce(nullif(order_sn, ''), nullif(order_id::text, '')) as order_key,
        COUNT(*) as occurrence_count
    FROM public.marketplace_orders
    GROUP BY 
        tenant_id,
        marketplace_account_id,
        coalesce(nullif(order_sn, ''), nullif(order_id::text, ''))
    HAVING COUNT(*) > 1
)
SELECT * FROM duplicated_orders;

-- 3. Identify duplicates in marketplace_order_items
-- Groups by order_id and SKU mapping.
WITH duplicated_order_items AS (
    SELECT 
        tenant_id,
        marketplace_order_id,
        coalesce(nullif(marketplace_sku_id, ''), nullif(marketplace_sku, '')) as sku_key,
        COUNT(*) as occurrence_count
    FROM public.marketplace_order_items
    GROUP BY 
        tenant_id,
        marketplace_order_id,
        coalesce(nullif(marketplace_sku_id, ''), nullif(marketplace_sku, ''))
    HAVING COUNT(*) > 1
)
SELECT * FROM duplicated_order_items;

-- 4. Sample duplicate check query showing complete row details (Read-Only)
-- This can be used to investigate the exact rows of a known duplicated order
/*
SELECT 
    finance_report_id,
    order_id,
    statement_id,
    payout_amount,
    created_at
FROM public.marketplace_finance_reports
WHERE order_id IN (
    SELECT order_id 
    FROM public.marketplace_finance_reports 
    GROUP BY order_id, statement_id 
    HAVING count(*) > 1
)
ORDER BY order_id, created_at DESC;
*/
