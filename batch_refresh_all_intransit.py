import subprocess
import json

def run_vps(cmd_str):
    cmd = ['ssh', 'inventory-vps', cmd_str]
    res = subprocess.run(cmd, text=True, capture_output=True)
    if res.returncode != 0:
        print("VPS Error:", res.stderr)
        return ""
    return res.stdout.strip()

cron_secret = "4bb7142023541dee631ded0e18e7fddd7c45789cc6e89751154bc73cad21ffdd"

print("--- 1. GET ALL STUCK TIKTOK IN_TRANSIT ORDER IDS BEFORE JULY 15 ---")
sql_tt = """
SELECT external_order_id
FROM marketplace_orders
WHERE lower(marketplace) LIKE '%tiktok%'
  AND order_status IN ('IN_TRANSIT', 'SHIPPED', 'AWAITING_COLLECTION', 'AWAITING_SHIPMENT')
ORDER BY order_created_at ASC;
"""
tt_ids_str = run_vps(f'docker exec -i supabase-db psql -U postgres -d postgres -t -A -c "{sql_tt}"')
tt_ids = [line.strip() for line in tt_ids_str.split('\n') if line.strip()]
print(f"Total TikTok in-transit candidate orders: {len(tt_ids)}")

sql_acc = "SELECT marketplace_account_id, tenant_id FROM marketplace_accounts WHERE marketplace = 'tiktok_shop' AND status = 'active' LIMIT 1;"
acc_info = run_vps(f'docker exec -i supabase-db psql -U postgres -d postgres -t -A -c "{sql_acc}"')
acc_id, tenant_id = acc_info.split('|')

key = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJyb2xlIjoic2VydmljZV9yb2xlIiwiaXNzIjoic3VwYWJhc2UiLCJpYXQiOjE3ODEzNjU5OTAsImV4cCI6NDEwMjQ0NDgwMH0.TaqlY7FVaZ4a9XdNiWZXZLJxpakzQzMd6ET1xmghwfo"

# Batch in chunks of 50
chunk_size = 50
total_updated = 0
total_checked = 0

for i in range(0, len(tt_ids), chunk_size):
    chunk = tt_ids[i:i+chunk_size]
    print(f"\nProcessing chunk {i//chunk_size + 1} / {(len(tt_ids) + chunk_size - 1)//chunk_size} ({len(chunk)} orders)...")
    
    # We can pass explicit order ids or call tiktok API directly
    # Let's call TikTok API /order/202309/orders with ids=... via edge function
    payload = json.dumps({
        "tenant_id": tenant_id,
        "marketplace_account_id": acc_id,
        "action": "refresh_existing_status",
        "status_range_days": 90,
        "max_existing_orders": 200,
        "skip_completed_status_refresh": True,
        "explicit_order_ids": chunk
    }).replace('"', '\\"')

    curl_cmd = f"""curl -s -X POST "http://localhost:8050/functions/v1/marketplace-order-pull" -H "Content-Type: application/json" -H "x-marketplace-cron-secret: {cron_secret}" -d "{payload}" """
    out = run_vps(curl_cmd)
    print("Chunk Response:", out[:300])

print("\n--- DONE BATCH PROCESSING ---")
