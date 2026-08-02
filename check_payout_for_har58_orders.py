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
tenant_id = "ae730499-550b-4907-bb18-bbc2629c64f4"
acc_id = "6a6a6d63-fffb-431a-8812-191b9d87a84d"

test_order_ids = [
    "585009596505556120",
    "584905834089842159",
    "585091526700140276",
    "584864185192711209"
]

print("=== 1. CHECK IF FINANCE REPORT ROWS EXIST IN DATABASE FOR THESE ORDERS ===")
for order_id in test_order_ids:
    sql = f"SELECT id, order_id, payout_amount, net_settlement, received_amount, status, created_at, pulled_at FROM marketplace_finance_reports WHERE order_id = '{order_id}';"
    row = run_vps(f'docker exec -i supabase-db psql -U postgres -d postgres -t -A -c "{sql}"')
    print(f"Order {order_id} in marketplace_finance_reports: {row if row else 'NOT FOUND'}")

print("\n=== 2. CALL MARKETPLACE-FINANCE-PULL FOR THESE SPECIFIC ORDERS ===")
for order_id in test_order_ids:
    payload = json.dumps({
        "tenant_id": tenant_id,
        "marketplace_account_id": acc_id,
        "action": "pull_order_finance",
        "order_id": order_id,
        "days_back": 90
    }).replace('"', '\\"')
    curl_cmd = f"""curl -s -X POST "http://localhost:8050/functions/v1/marketplace-finance-pull" -H "Content-Type: application/json" -H "x-marketplace-cron-secret: {cron_secret}" -d "{payload}" """
    out = run_vps(curl_cmd)
    print(f"Pull Finance Response for {order_id}: {out[:300]}")

