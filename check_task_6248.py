import subprocess

def run_sql(sql):
    cmd = ['ssh', 'inventory-vps', f'docker exec -i supabase-db psql -U postgres -d postgres -t -A -c "{sql}"']
    res = subprocess.run(cmd, text=True, capture_output=True)
    if res.returncode != 0:
        print("SQL Error:", res.stderr)
        return ""
    return res.stdout.strip()

print("--- RE-CHECK TIKTOK ORDERS MISSING ITEMS ---")
sql_missing = """
SELECT count(o.marketplace_order_id)
FROM marketplace_orders o
LEFT JOIN marketplace_order_items i ON i.marketplace_order_id = o.marketplace_order_id
WHERE lower(o.marketplace) LIKE '%tiktok%'
  AND i.marketplace_order_item_id IS NULL;
"""
print("TikTok orders missing items:", run_sql(sql_missing))

print("--- RE-CHECK SHOPEE ORDERS MISSING ITEMS ---")
sql_missing_sp = """
SELECT count(o.marketplace_order_id)
FROM marketplace_orders o
LEFT JOIN marketplace_order_items i ON i.marketplace_order_id = o.marketplace_order_id
WHERE lower(o.marketplace) LIKE '%shopee%'
  AND i.marketplace_order_item_id IS NULL;
"""
print("Shopee orders missing items:", run_sql(sql_missing_sp))

print("\n--- SAMPLE TIKTOK ORDER ITEM POPULATED ---")
sql_sample = """
SELECT marketplace_order_id, marketplace_sku, marketplace_seller_sku, local_sku, product_name, variant_name, qty, gross_amount
FROM marketplace_order_items
WHERE lower(marketplace) LIKE '%tiktok%'
ORDER BY created_at DESC LIMIT 5;
"""
print(run_sql(sql_sample))

