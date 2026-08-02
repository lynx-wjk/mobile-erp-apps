import subprocess
import json

def run_sql(sql):
    cmd = ['ssh', 'inventory-vps', f'docker exec -i supabase-db psql -U postgres -d postgres -t -A -c "{sql}"']
    res = subprocess.run(cmd, text=True, capture_output=True)
    if res.returncode != 0:
        print("SQL Error:", res.stderr)
        return ""
    return res.stdout.strip()

secret = run_sql("SELECT app_private.get_runtime_secret('marketplace_cron_secret');")

payload = json.dumps({
    "marketplace": "tiktok_shop",
    "mode": "recent",
    "tenant_id": "ae730499-550b-4907-bb18-bbc2629c64f4",
    "marketplace_account_id": "6a6a6d63-fffb-431a-8812-191b9d87a84d"
})

cmd = [
    'ssh', 'inventory-vps',
    f'docker exec -i supabase-kong curl -sS -X POST "http://localhost:8000/functions/v1/marketplace-order-pull" -H "Content-Type: application/json" -H "x-marketplace-cron-secret: {secret}" -d \'{payload}\''
]
res = subprocess.run(cmd, text=True, capture_output=True)
print("Kong curl stdout:", res.stdout)
print("Kong curl stderr:", res.stderr)

