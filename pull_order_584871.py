import subprocess
import json
import time

def run_sql(sql):
    cmd = ['ssh', 'inventory-vps', f'docker exec -i supabase-db psql -U postgres -d postgres -t -A -c "{sql}"']
    res = subprocess.run(cmd, text=True, capture_output=True)
    if res.returncode != 0:
        print("SQL Error:", res.stderr)
        return ""
    return res.stdout.strip()

secret = run_sql("SELECT app_private.get_runtime_secret('marketplace_cron_secret');")
order_id = '584871522068366376'
account_id = '6a6a6d63-fffb-431a-8812-191b9d87a84d'

payload = json.dumps({
    "action": "pull_finance_by_order",
    "params": {
        "order_id": order_id,
        "account_id": account_id,
        "marketplace_account_id": account_id
    }
})

# Curl directly inside edge functions container or localhost
cmd = [
    'ssh', 'inventory-vps',
    f"curl -sS -X POST 'http://localhost:8000/functions/v1/marketplace-tiktok-service' -H 'Content-Type: application/json' -H 'x-marketplace-cron-secret: {secret}' -d '{payload}'"
]
res = subprocess.run(cmd, text=True, capture_output=True)
print("--- RAW RESPONSE FROM TIKTOK FINANCE PULL ---")
print(res.stdout)

