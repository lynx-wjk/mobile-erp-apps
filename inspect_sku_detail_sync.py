import subprocess

def run_sql(sql):
    cmd = ['ssh', 'inventory-vps', f'docker exec -i supabase-db psql -U postgres -d postgres -t -A -c "{sql}"']
    res = subprocess.run(cmd, text=True, capture_output=True)
    if res.returncode != 0:
        print("SQL Error:", res.stderr)
        return ""
    return res.stdout.strip()

print("--- 1. CHECK ORDERS WITHOUT ORDER ITEMS (LAST 100 ORDERS PER MARKETPLACE) ---")
sql_orders_without_items = """
SELECT o.marketplace, count(o.marketplace_order_id) as total_orders,
       count(i.marketplace_order_item_id) as orders_with_items,
       count(o.marketplace_order_id) - count(DISTINCT i.marketplace_order_id) as orders_missing_items
FROM (
  SELECT marketplace_order_id, marketplace
  FROM marketplace_orders
  ORDER BY order_created_at DESC
  LIMIT 500
) o
LEFT JOIN marketplace_order_items i ON i.marketplace_order_id = o.marketplace_order_id
GROUP BY o.marketplace;
"""
print(run_sql(sql_orders_without_items))

print("\n--- 2. TIKTOK ORDERS IN MARKETPLACE_ORDERS MISSING ITEMS IN MARKETPLACE_ORDER_ITEMS ---")
sql_missing_tt_items = """
SELECT o.marketplace_order_id, o.order_id, o.order_sn, o.order_status, o.order_created_at
FROM marketplace_orders o
LEFT JOIN marketplace_order_items i ON i.marketplace_order_id = o.marketplace_order_id
WHERE lower(o.marketplace) LIKE '%tiktok%'
  AND i.marketplace_order_item_id IS NULL
ORDER BY o.order_created_at DESC
LIMIT 20;
"""
print(run_sql(sql_missing_tt_items))

print("\n--- 3. SAMPLE ORDER ITEMS FOR TIKTOK SHOP ---")
sql_sample_items = """
SELECT marketplace, marketplace_sku, marketplace_sku_id, marketplace_seller_sku, local_sku, product_name, variant_name, qty, unit_gross_amount
FROM marketplace_order_items
WHERE lower(marketplace) LIKE '%tiktok%'
ORDER BY created_at DESC
LIMIT 10;
"""
print(run_sql(sql_sample_items))

print("\n--- 4. CHECK SPECIFIC ORDER 585027028427834403 ---")
sql_order_585 = """
SELECT o.marketplace_order_id, o.order_id, o.order_sn, o.order_status, o.created_at,
       i.marketplace_order_item_id, i.marketplace_sku, i.product_name, i.variant_name
FROM marketplace_orders o
LEFT JOIN marketplace_order_items i ON i.marketplace_order_id = o.marketplace_order_id
WHERE o.order_id = '585027028427834403' OR o.order_sn = '585027028427834403';
"""
print(run_sql(sql_order_585))

print("\n--- 5. CHECK FINANCE ITEMS & REPORTS FOR 585027028427834403 ---")
sql_finance_585 = """
SELECT 'reports' as src, order_id, gross_amount, payout_amount, net_settlement, created_at
FROM marketplace_finance_reports
WHERE order_id = '585027028427834403'
UNION ALL
SELECT 'items' as src, order_id, gross_amount, received_amount as payout_amount, net_settlement, created_at
FROM marketplace_finance_items
WHERE order_id = '585027028427834403';
"""
print(run_sql(sql_finance_585))

