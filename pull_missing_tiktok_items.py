import subprocess
import json

def run_sql(sql):
    cmd = ['ssh', 'inventory-vps', f'docker exec -i supabase-db psql -U postgres -d postgres -t -A -c "{sql}"']
    res = subprocess.run(cmd, text=True, capture_output=True)
    if res.returncode != 0:
        print("SQL Error:", res.stderr)
        return ""
    return res.stdout.strip()

print("--- FETCHING LIST OF MISSING TIKTOK ORDER IDS ---")
sql_missing_ids = """
SELECT o.order_id
FROM marketplace_orders o
LEFT JOIN marketplace_order_items i ON i.marketplace_order_id = o.marketplace_order_id
WHERE lower(o.marketplace) LIKE '%tiktok%'
  AND i.marketplace_order_item_id IS NULL;
"""
raw = run_sql(sql_missing_ids)
order_ids = [x.strip() for x in raw.splitlines() if x.strip()]
print(f"Found {len(order_ids)} orders missing items.")

if order_ids:
    print(f"Triggering marketplace-tiktok-service pull_orders for missing orders...")
    payload = json.dumps({
        "action": "pull_orders",
        "bootstrap_days": 180,
        "force": True
    })
    cmd = [
        'ssh', 'inventory-vps',
        f"curl -sS -X POST 'http://localhost:8000/functions/v1/marketplace-tiktok-service' -H 'Content-Type: application/json' -H 'x-marketplace-cron-secret: secret' -d '{payload}'"
    ]
    res = subprocess.run(cmd, text=True, capture_output=True)
    print("Response:", res.stdout[:1000])

print("\n--- RE-CHECKING MISSING COUNT AFTER TIKTOK SERVICE RUN ---")
print("Missing items count:", run_sql(sql_missing_ids))

