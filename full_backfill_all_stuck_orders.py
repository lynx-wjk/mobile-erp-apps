import subprocess
import json
import time

def run_vps(cmd_str):
    cmd = ['ssh', 'inventory-vps', cmd_str]
    res = subprocess.run(cmd, text=True, capture_output=True)
    if res.returncode != 0:
        print("VPS Error:", res.stderr)
        return ""
    return res.stdout.strip()

cron_secret = "4bb7142023541dee631ded0e18e7fddd7c45789cc6e89751154bc73cad21ffdd"
key = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJyb2xlIjoic2VydmljZV9yb2xlIiwiaXNzIjoic3VwYWJhc2UiLCJpYXQiOjE3ODEzNjU5OTAsImV4cCI6NDEwMjQ0NDgwMH0.TaqlY7FVaZ4a9XdNiWZXZLJxpakzQzMd6ET1xmghwfo"

print("=== 1. FETCH ALL ACTIVE MARKETPLACE ACCOUNTS ===")
sql_accs = "SELECT marketplace_account_id, tenant_id, marketplace, shop_name FROM marketplace_accounts WHERE status = 'active' AND is_deleted = false;"
accs_raw = run_vps(f'docker exec -i supabase-db psql -U postgres -d postgres -t -A -c "{sql_accs}"')
accs = [line.split('|') for line in accs_raw.split('\n') if '|' in line]
print(f"Found {len(accs)} active marketplace accounts.")

for acc_id, tenant_id, marketplace, shop_name in accs:
    print(f"\n=======================================================")
    print(f"Processing Account: {shop_name} ({marketplace}) [{acc_id}]")
    print(f"=======================================================")

    sql_in_transit = f"""
    SELECT external_order_id
    FROM marketplace_orders
    WHERE marketplace_account_id = '{acc_id}'
      AND order_status IN ('IN_TRANSIT', 'SHIPPED', 'AWAITING_COLLECTION', 'AWAITING_SHIPMENT', 'UNPAID', 'PROCESSING', 'ON_HOLD')
    ORDER BY order_created_at ASC;
    """
    ids_raw = run_vps(f'docker exec -i supabase-db psql -U postgres -d postgres -t -A -c "{sql_in_transit}"')
    ids = [line.strip() for line in ids_raw.split('\n') if line.strip()]
    print(f"Total candidate in-transit orders to refresh: {len(ids)}")

    chunk_size = 50
    total_updated = 0
    total_checked = 0

    for i in range(0, len(ids), chunk_size):
        chunk = ids[i:i+chunk_size]
        print(f"  Chunk {i//chunk_size + 1}/{(len(ids)+chunk_size-1)//chunk_size} ({len(chunk)} orders)...", end="", flush=True)

        payload = json.dumps({
            "tenant_id": tenant_id,
            "marketplace_account_id": acc_id,
            "action": "refresh_existing_status",
            "status_range_days": 90,
            "max_existing_orders": len(chunk),
            "skip_completed_status_refresh": True,
            "explicit_order_ids": chunk
        }).replace('"', '\\"')

        curl_cmd = f"""curl -s -X POST "http://localhost:8050/functions/v1/marketplace-order-pull" -H "Content-Type: application/json" -H "x-marketplace-cron-secret: {cron_secret}" -d "{payload}" """
        out = run_vps(curl_cmd)
        try:
            resp_json = json.loads(out)
            chk = resp_json.get('checked', 0)
            upd = resp_json.get('updated', 0)
            total_checked += chk
            total_updated += upd
            print(f" OK (checked={chk}, updated={upd})")
        except Exception as e:
            print(f" ERR: {out[:150]}")
        
        time.sleep(0.5)

    print(f"Account {shop_name} Summary: Checked {total_checked}, Updated {total_updated} orders.")

print("\n=== ALL ACCOUNTS BATCH STATUS REFRESH COMPLETE ===")

