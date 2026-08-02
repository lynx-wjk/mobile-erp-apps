import subprocess
import json

def run_sql(sql):
    cmd = ['ssh', 'inventory-vps', f'docker exec -i supabase-db psql -U postgres -d postgres -t -A -c "{sql}"']
    res = subprocess.run(cmd, text=True, capture_output=True)
    if res.returncode != 0:
        print("SQL Error:", res.stderr)
        return ""
    return res.stdout.strip()

print("--- 1. BACKFILL NULL FIELDS IN MARKETPLACE_ORDER_ITEMS ---")
sql_backfill_items = """
UPDATE marketplace_order_items
SET 
  marketplace_sku = COALESCE(nullif(marketplace_sku, ''), nullif(marketplace_sku_id, ''), nullif(remote_sku_id, ''), seller_sku),
  marketplace_sku_id = COALESCE(nullif(marketplace_sku_id, ''), nullif(remote_sku_id, '')),
  marketplace_seller_sku = COALESCE(nullif(marketplace_seller_sku, ''), nullif(seller_sku, '')),
  seller_sku = COALESCE(nullif(seller_sku, ''), nullif(marketplace_seller_sku, '')),
  local_sku = COALESCE(nullif(local_sku, ''), nullif(mapped_local_sku, '')),
  mapped_local_sku = COALESCE(nullif(mapped_local_sku, ''), nullif(local_sku, '')),
  marketplace_product_name = COALESCE(nullif(marketplace_product_name, ''), nullif(product_name, '')),
  product_name = COALESCE(nullif(product_name, ''), nullif(marketplace_product_name, '')),
  marketplace_variant_name = COALESCE(nullif(marketplace_variant_name, ''), nullif(variant_name, ''), nullif(variation_name, '')),
  variant_name = COALESCE(nullif(variant_name, ''), nullif(marketplace_variant_name, ''), nullif(variation_name, '')),
  variation_name = COALESCE(nullif(variation_name, ''), nullif(variant_name, ''), nullif(marketplace_variant_name, '')),
  qty = GREATEST(COALESCE(qty, quantity, 1), 1),
  quantity = GREATEST(COALESCE(quantity, qty, 1), 1),
  unit_gross_amount = COALESCE(unit_gross_amount, CASE WHEN qty > 0 THEN gross_amount / qty ELSE gross_amount END, paid_amount, 0),
  gross_amount = COALESCE(gross_amount, unit_gross_amount * GREATEST(COALESCE(qty, quantity, 1), 1), paid_amount, 0)
WHERE marketplace_sku IS NULL 
   OR marketplace_seller_sku IS NULL 
   OR local_sku IS NULL 
   OR qty IS NULL 
   OR gross_amount IS NULL;
"""
print(run_sql(sql_backfill_items))

print("\n--- 2. TRIGGER TIKTOK ORDER RE-SYNC VIA EDGE FUNCTION ---")
cmd_tiktok = [
  'ssh', 'inventory-vps',
  'curl -sS -X POST "http://localhost:8000/functions/v1/marketplace-tiktok-service" -H "Content-Type: application/json" -H "x-marketplace-cron-secret: secret" -d \'{"action":"pull_orders","bootstrap_days":60,"force":true}\''
]
res_tt = subprocess.run(cmd_tiktok, text=True, capture_output=True)
print("TikTok Sync Response:", res_tt.stdout[:500])

print("\n--- 3. TRIGGER SHOPEE & TIKTOK ORDER DISPATCHER ---")
cmd_dispatcher = [
  'ssh', 'inventory-vps',
  'curl -sS -X POST "http://localhost:8000/functions/v1/marketplace-order-dispatcher" -H "Content-Type: application/json" -H "x-marketplace-cron-secret: secret" -d \'{"max_accounts":5,"lock_seconds":900}\''
]
res_disp = subprocess.run(cmd_dispatcher, text=True, capture_output=True)
print("Dispatcher Response:", res_disp.stdout[:500])

print("\n--- 4. RE-CHECK TIKTOK ORDERS MISSING ITEMS ---")
sql_missing = """
SELECT count(o.marketplace_order_id)
FROM marketplace_orders o
LEFT JOIN marketplace_order_items i ON i.marketplace_order_id = o.marketplace_order_id
WHERE lower(o.marketplace) LIKE '%tiktok%'
  AND i.marketplace_order_item_id IS NULL;
"""
print("TikTok orders missing items after sync:", run_sql(sql_missing))

