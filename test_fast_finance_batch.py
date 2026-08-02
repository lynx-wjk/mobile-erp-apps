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
key = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJyb2xlIjoic2VydmljZV9yb2xlIiwiaXNzIjoic3VwYWJhc2UiLCJpYXQiOjE3ODEzNjU5OTAsImV4cCI6NDEwMjQ0NDgwMH0.TaqlY7FVaZ4a9XdNiWZXZLJxpakzQzMd6ET1xmghwfo"

print("=== CALL MARKETPLACE-TIKTOK-SERVICE DIRECTLY WITH SMALL BATCH ===")
payload = json.dumps({
    "action": "process_finance_sync_jobs",
    "params": {
        "tenant_id": tenant_id,
        "account_id": acc_id,
        "mode": "recent_unpaid",
        "days_back": 90,
        "unpaid_backlog_days": 90,
        "auto_unpaid_backlog_90d": True,
        "missing_only": True,
        "max_orders": 30,
        "max_batches_per_job": 2,
        "max_statements": 4,
        "max_transactions": 50,
        "max_order_details": 30,
        "include_sku_details": True,
        "enqueue": True,
        "force_requeue": True
    }
}).replace('"', '\\"')

curl_cmd = f"""curl -s -X POST "http://localhost:8050/functions/v1/marketplace-tiktok-service" -H "Content-Type: application/json" -H "Authorization: Bearer {key}" -H "apikey: {key}" -H "x-marketplace-cron-secret: {cron_secret}" -d "{payload}" """
out = run_vps(curl_cmd)
print("Response:", out[:600])

