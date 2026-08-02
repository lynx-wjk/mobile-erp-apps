import subprocess
import json

def run_sql(sql):
    cmd = ['ssh', 'inventory-vps', f'docker exec -i supabase-db psql -U postgres -d postgres -t -A -c "{sql}"']
    res = subprocess.run(cmd, text=True, capture_output=True)
    if res.returncode != 0:
        print("SQL Error:", res.stderr)
        return ""
    return res.stdout.strip()

print("--- CALLING MARKETPLACE-ORDER-PULL FOR TIKTOK SHOP ---")
payload = json.dumps({
    "marketplace": "tiktok_shop",
    "mode": "recent",
    "tenant_id": "ae730499-550b-4907-bb18-bbc2629c64f4",
    "marketplace_account_id": "6a6a6d63-fffb-431a-8812-191b9d87a84d"
})
cmd = [
    'ssh', 'inventory-vps',
    f"curl -sS -X POST 'http://localhost:8000/functions/v1/marketplace-order-pull' -H 'Content-Type: application/json' -H 'x-marketplace-cron-secret: secret' -d '{payload}'"
]
res = subprocess.run(cmd, text=True, capture_output=True)
print("Order Pull Response:", res.stdout[:1000])

print("\n--- CHECK MISSING COUNT ---")
sql_missing = """
SELECT count(o.marketplace_order_id)
FROM marketplace_orders o
LEFT JOIN marketplace_order_items i ON i.marketplace_order_id = o.marketplace_order_id
WHERE lower(o.marketplace) LIKE '%tiktok%'
  AND i.marketplace_order_item_id IS NULL;
"""
print("TikTok orders missing items count:", run_sql(sql_missing))
