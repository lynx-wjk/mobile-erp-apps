import subprocess
import json
import requests
import time
import hmac
import hashlib

def run_sql(sql):
    cmd = ['ssh', 'inventory-vps', f'docker exec -i supabase-db psql -U postgres -d postgres -t -A -c "{sql}"']
    res = subprocess.run(cmd, text=True, capture_output=True)
    if res.returncode != 0:
        print("SQL Error:", res.stderr)
        return ""
    return res.stdout.strip()

print("--- 1. CALL ACTION_PULL_FINANCE_BY_ORDER IN MARKETPLACE-TIKTOK-SERVICE ---")
payload = json.dumps({
    "action": "pull_finance_by_order",
    "order_id": "584871522068366376",
    "tenant_id": "ae730499-550b-4907-bb18-bbc2629c64f4",
    "marketplace_account_id": "6a6a6d63-fffb-431a-8812-191b9d87a84d"
})
cmd = [
    'ssh', 'inventory-vps',
    f"curl -sS -X POST 'http://localhost:8000/functions/v1/marketplace-tiktok-service' -H 'Content-Type: application/json' -H 'x-marketplace-cron-secret: secret' -d '{payload}'"
]
res = subprocess.run(cmd, text=True, capture_output=True)
print("Response:", res.stdout[:2000])

