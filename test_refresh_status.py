import subprocess
import json

def run_vps(cmd_str):
    cmd = ['ssh', 'inventory-vps', cmd_str]
    res = subprocess.run(cmd, text=True, capture_output=True)
    if res.returncode != 0:
        print("VPS Error:", res.stderr)
        return ""
    return res.stdout.strip()

print("--- GET MARKETPLACE ACCOUNT ID FOR TIKTOK SHOP ---")
sql_acc = "SELECT marketplace_account_id, tenant_id, shop_name FROM marketplace_accounts WHERE marketplace = 'tiktok_shop' AND status = 'active' LIMIT 1;"
acc_info = run_vps(f'docker exec -i supabase-db psql -U postgres -d postgres -t -A -c "{sql_acc}"')
print("Account Info:", acc_info)

acc_id, tenant_id, shop_name = acc_info.split('|')

key = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJyb2xlIjoic2VydmljZV9yb2xlIiwiaXNzIjoic3VwYWJhc2UiLCJpYXQiOjE3ODEzNjU5OTAsImV4cCI6NDEwMjQ0NDgwMH0.TaqlY7FVaZ4a9XdNiWZXZLJxpakzQzMd6ET1xmghwfo"

print("\n--- TRIGGER REFRESH_EXISTING_STATUS IN MARKETPLACE-ORDER-PULL ---")
payload = json.dumps({
    "tenant_id": tenant_id,
    "marketplace_account_id": acc_id,
    "action": "refresh_existing_status",
    "status_range_days": 60,
    "max_existing_orders": 200,
    "skip_completed_status_refresh": True
}).replace('"', '\\"')

curl_cmd = f"""curl -s -X POST "http://localhost:8050/functions/v1/marketplace-order-pull" -H "Content-Type: application/json" -H "Authorization: Bearer {key}" -d "{payload}" """
out = run_vps(curl_cmd)
print("Response:", out)

