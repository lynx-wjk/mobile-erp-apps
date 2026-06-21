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
SELECT *
FROM duplicated_order_items
ORDER BY occurrence_count DESC, marketplace_order_id
LIMIT 200;

-- 4. Marketplace finance gap by account/date (Read-Only)
-- Change audit_start/audit_end only. This distinguishes existing marketplace
-- order ingestion from missing marketplace finance settlement ingestion.
WITH params AS (
    SELECT date '2026-06-21' AS audit_start, date '2026-06-21' AS audit_end
),
finance_by_account AS (
    SELECT
        coalesce(fr.marketplace, a.marketplace, '-') AS marketplace,
        fr.marketplace_account_id,
        coalesce(a.store_alias, a.shop_name, fr.shop_id, '-') AS account_label,
        COUNT(*) AS finance_rows,
        COUNT(DISTINCT nullif(fr.order_id, '')) AS finance_orders,
        coalesce(SUM(fr.gross_amount), 0) AS finance_gross,
        coalesce(SUM(fr.payout_amount), 0) AS finance_payout
    FROM public.marketplace_finance_reports fr
    LEFT JOIN public.marketplace_accounts a
        ON a.marketplace_account_id = fr.marketplace_account_id
    CROSS JOIN params p
    WHERE fr.period_start BETWEEN p.audit_start AND p.audit_end
    GROUP BY 1, 2, 3
),
orders_by_account AS (
    SELECT
        coalesce(o.marketplace, a.marketplace, '-') AS marketplace,
        o.marketplace_account_id,
        coalesce(a.store_alias, a.shop_name, o.shop_id, '-') AS account_label,
        COUNT(*) AS order_rows,
        COUNT(DISTINCT coalesce(
            nullif(o.order_sn, ''),
            nullif(o.order_id, ''),
            nullif(o.external_order_id, ''),
            nullif(o.remote_order_id, '')
        )) AS orders
    FROM public.marketplace_orders o
    LEFT JOIN public.marketplace_accounts a
        ON a.marketplace_account_id = o.marketplace_account_id
    CROSS JOIN params p
    WHERE coalesce(o.order_created_at, o.created_time, o.paid_at, o.created_at)::date
        BETWEEN p.audit_start AND p.audit_end
    GROUP BY 1, 2, 3
)
SELECT
    coalesce(o.marketplace, f.marketplace) AS marketplace,
    coalesce(o.marketplace_account_id, f.marketplace_account_id) AS marketplace_account_id,
    coalesce(o.account_label, f.account_label) AS account_label,
    coalesce(o.order_rows, 0) AS order_rows,
    coalesce(o.orders, 0) AS order_count,
    coalesce(f.finance_rows, 0) AS finance_rows,
    coalesce(f.finance_orders, 0) AS finance_order_count,
    coalesce(f.finance_gross, 0) AS finance_gross,
    coalesce(f.finance_payout, 0) AS finance_payout
FROM orders_by_account o
FULL OUTER JOIN finance_by_account f
    ON f.marketplace_account_id = o.marketplace_account_id
ORDER BY marketplace, account_label;

-- 5. Cost source coverage used by Arus Kas/Biaya (Read-Only)
WITH params AS (
    SELECT date '2026-06-01' AS audit_start, date '2026-06-21' AS audit_end
),
sources AS (
    SELECT
        'manual_cash_out' AS source,
        COUNT(*) AS rows,
        coalesce(SUM(abs(c.amount)), 0) AS amount
    FROM public.finance_company_cash_adjustments c
    CROSS JOIN params p
    WHERE c.adjustment_date BETWEEN p.audit_start AND p.audit_end
      AND lower(coalesce(c.direction, '')) = 'out'
    UNION ALL
    SELECT
        'approved_operational_expense' AS source,
        COUNT(*) AS rows,
        coalesce(SUM(abs(e.amount)), 0) AS amount
    FROM public.finance_operational_expenses e
    CROSS JOIN params p
    WHERE coalesce(e.expense_date, e.paid_at) BETWEEN p.audit_start AND p.audit_end
      AND lower(coalesce(e.status, 'paid')) NOT IN ('void', 'voided', 'cancelled', 'canceled', 'deleted')
    UNION ALL
    SELECT
        'approved_purchase_requests' AS source,
        COUNT(*) AS rows,
        coalesce(SUM(abs(pr.total_amount)), 0) AS amount
    FROM public.purchase_requests pr
    CROSS JOIN params p
    WHERE pr.tanggal_beli BETWEEN p.audit_start AND p.audit_end
      AND lower(coalesce(pr.status, '')) IN ('approved', 'verified', 'accepted', 'done', 'paid')
    UNION ALL
    SELECT
        'approved_purchases' AS source,
        COUNT(*) AS rows,
        coalesce(SUM(abs(pu.total_pembelian)), 0) AS amount
    FROM public.purchases pu
    CROSS JOIN params p
    WHERE pu.tanggal BETWEEN p.audit_start AND p.audit_end
      AND lower(coalesce(pu.status, '')) IN ('approved', 'verified', 'accepted', 'done', 'paid')
    UNION ALL
    SELECT
        'paid_production_tailor_payment' AS source,
        COUNT(*) AS rows,
        coalesce(SUM(abs(tp.amount)), 0) AS amount
    FROM public.production_tailor_payments tp
    CROSS JOIN params p
    WHERE tp.payment_date BETWEEN p.audit_start AND p.audit_end
      AND lower(coalesce(tp.payment_status, '')) = 'sudah_bayar'
      AND lower(coalesce(tp.payment_type, '')) IN ('sewing_payment', 'kasbon')
      AND coalesce(tp.is_voided, false) = false
)
SELECT * FROM sources ORDER BY source;

-- 6. Sample duplicate check query showing complete row details (Read-Only)
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
