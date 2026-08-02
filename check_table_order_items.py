import subprocess

def run_sql(sql):
    cmd = ['ssh', 'inventory-vps', f'docker exec -i supabase-db psql -U postgres -d postgres -t -A -c "{sql}"']
    res = subprocess.run(cmd, text=True, capture_output=True)
    if res.returncode != 0:
        print("SQL Error:", res.stderr)
        return ""
    return res.stdout.strip()

print("--- COLUMNS IN MARKETPLACE_ORDER_ITEMS ---")
sql_cols = """
SELECT column_name, data_type 
FROM information_schema.columns 
WHERE table_name = 'marketplace_order_items'
ORDER BY ordinal_position;
"""
print(run_sql(sql_cols))

print("\n--- SAMPLE TIKTOK ROW IN MARKETPLACE_ORDER_ITEMS ---")
sql_sample = """
SELECT marketplace_order_item_id, marketplace, order_sn, marketplace_sku_id, remote_sku_id, marketplace_sku, marketplace_seller_sku, seller_sku, remote_seller_sku, local_sku, mapped_local_sku, gross_amount, paid_amount, unit_gross_amount, item_price, qty, quantity
FROM marketplace_order_items
WHERE lower(marketplace) LIKE '%tiktok%'
ORDER BY created_at DESC LIMIT 5;
"""
print(run_sql(sql_sample))

print("\n--- SAMPLE SHOPEE ROW IN MARKETPLACE_ORDER_ITEMS ---")
sql_shopee = """
SELECT marketplace_order_item_id, marketplace, order_sn, marketplace_sku_id, remote_sku_id, marketplace_sku, marketplace_seller_sku, seller_sku, remote_seller_sku, local_sku, mapped_local_sku, gross_amount, paid_amount, unit_gross_amount, item_price, qty, quantity
FROM marketplace_order_items
WHERE lower(marketplace) LIKE '%shopee%'
ORDER BY created_at DESC LIMIT 5;
"""
print(run_sql(sql_shopee))
