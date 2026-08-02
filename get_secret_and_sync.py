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
print("Runtime secret length:", len(secret))

payload = json.dumps({
    "max_accounts": 5,
    "lock_seconds": 900
})
cmd = [
    'ssh', 'inventory-vps',
    f"curl -sS -X POST 'http://localhost:8000/functions/v1/marketplace-order-dispatcher' -H 'Content-Type: application/json' -H 'x-marketplace-cron-secret: {secret}' -d '{payload}'"
]
res = subprocess.run(cmd, text=True, capture_output=True)
print("Dispatcher response:", res.stdout[:1000])

print("\n--- RE-CHECKING MISSING COUNT ---")
sql_missing = """
SELECT count(o.marketplace_order_id)
FROM marketplace_orders o
LEFT JOIN marketplace_order_items i ON i.marketplace_order_id = o.marketplace_order_id
WHERE lower(o.marketplace) LIKE '%tiktok%'
  AND i.marketplace_order_item_id IS NULL;
"""
print("TikTok orders missing items count:", run_sql(sql_missing))
