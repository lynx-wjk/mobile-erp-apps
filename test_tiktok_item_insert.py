import subprocess

def run_sql(sql):
    cmd = ['ssh', 'inventory-vps', f'docker exec -i supabase-db psql -U postgres -d postgres -t -A -c "{sql}"']
    res = subprocess.run(cmd, text=True, capture_output=True)
    if res.returncode != 0:
        print("SQL Error:", res.stderr)
        return ""
    return res.stdout.strip()

print("--- 1. CHECK TIKTOK ORDERS MISSING ITEMS ---")
sql_missing = """
SELECT count(o.marketplace_order_id)
FROM marketplace_orders o
LEFT JOIN marketplace_order_items i ON i.marketplace_order_id = o.marketplace_order_id
WHERE lower(o.marketplace) LIKE '%tiktok%'
  AND i.marketplace_order_item_id IS NULL;
"""
print("TikTok orders missing items:", run_sql(sql_missing))

print("--- 2. CHECK SHOPEE ORDERS MISSING ITEMS ---")
sql_missing_shopee = """
SELECT count(o.marketplace_order_id)
FROM marketplace_orders o
LEFT JOIN marketplace_order_items i ON i.marketplace_order_id = o.marketplace_order_id
WHERE lower(o.marketplace) LIKE '%shopee%'
  AND i.marketplace_order_item_id IS NULL;
"""
print("Shopee orders missing items:", run_sql(sql_missing_shopee))

print("\n--- 3. SAMPLE SHOPEE ORDER ITEMS FIELDS ---")
sql_shopee_sample = """
SELECT marketplace_sku_id, marketplace_sku, marketplace_seller_sku, seller_sku, local_sku, product_name, variant_name, variation_name, qty, quantity, gross_amount, paid_amount, unit_gross_amount, item_price
FROM marketplace_order_items
WHERE lower(marketplace) LIKE '%shopee%'
ORDER BY created_at DESC LIMIT 3;
"""
print(run_sql(sql_shopee_sample))
